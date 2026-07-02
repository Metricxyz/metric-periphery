// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MetricOmmSwapRouterBase} from "./base/MetricOmmSwapRouterBase.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {SelfPermit} from "./base/SelfPermit.sol";
import {IMetricOmmSimpleRouter} from "./interfaces/IMetricOmmSimpleRouter.sol";
import {IMulticall} from "./interfaces/IMulticall.sol";
import {MetricOmmSwapPath} from "./libraries/MetricOmmSwapPath.sol";
import {MetricOmmSwapInputs} from "./libraries/MetricOmmSwapInputs.sol";
import {MetricOmmSwapResults} from "./libraries/MetricOmmSwapResults.sol";

/// @title MetricOmmSimpleRouter
/// @notice Exact-input and exact-output swaps through one or more MetricOmm pools.
/// @dev Expected callback pool, payer, token, and swap mode are stored in transient storage at entry.

contract MetricOmmSimpleRouter is MetricOmmSwapRouterBase, PeripheryPayments, SelfPermit, IMetricOmmSimpleRouter {
  /// @notice Transient callback mode is not supported by this router.
  /// @param callbackMode Unrecognized mode read from transient storage.
  error InvalidCallbackMode(uint8 callbackMode);

  constructor(address weth, address factory) MetricOmmSwapRouterBase(factory) PeripheryPayments(weth) {}

  // ============ Types ============

  struct ExactOutputIterateCallbackData {
    address[] tokens;
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint256 amountInMax;
  }

  // ============ External: callback ============

  /// @inheritdoc IMulticall
  function multicall(bytes[] calldata data) public payable override returns (bytes[] memory results) {
    results = new bytes[](data.length);
    for (uint256 i = 0; i < data.length; i++) {
      results[i] = Address.functionDelegateCall(address(this), data[i]);
    }
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
    if (amount0Delta <= 0 && amount1Delta <= 0) revert InvalidSwapDeltas();

    _requireExpectedCallbackCaller(msg.sender);

    uint8 callbackMode = _getCallbackMode();

    if (callbackMode == CALLBACK_MODE_JUST_PAY) {
      _justPayCallback(amount0Delta, amount1Delta);
      return;
    }
    if (callbackMode == CALLBACK_MODE_EXACT_OUTPUT_ITERATE) {
      _exactOutputIterateCallback(amount0Delta, amount1Delta, data);
      return;
    }
    revert InvalidCallbackMode(callbackMode);
  }

  // ============ External: exact input ============

  /// @inheritdoc IMetricOmmSimpleRouter
  function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
    _checkDeadline(params.deadline);
    uint128 priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(params.zeroForOne, params.priceLimitX64);

    _setNextCallbackContext(params.pool, CALLBACK_MODE_JUST_PAY, msg.sender, params.tokenIn);
    (int128 amount0Delta, int128 amount1Delta) = IMetricOmmPoolActions(params.pool)
      .swap(
        params.recipient,
        params.zeroForOne,
        MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountIn),
        priceLimitX64,
        "",
        params.extensionData
      );
    int128 out = MetricOmmSwapResults.extractAmountOut(params.zeroForOne, amount0Delta, amount1Delta);
    amountOut = MetricOmmSwapInputs.int128ToUint128(out);
    if (amountOut < params.amountOutMinimum) revert InsufficientOutput(amountOut, params.amountOutMinimum);

    _clearExpectedCallbackPool();
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Walks `pools[0..n-1]` forward. Each hop swaps a positive `amountSpecified`; the prior hop's output
  ///      becomes the next hop's input. Intermediate tokens stay on this contract; the final hop sends output to
  ///      `recipient`.
  function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
    _checkDeadline(params.deadline);
    _validatePath(params.tokens, params.pools, params.extensionDatas);

    uint256 last = params.pools.length - 1;
    int128 amount = MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountIn);

    for (uint256 i = 0; i <= last; i++) {
      address pool = params.pools[i];
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, i);

      _setNextCallbackContext(pool, CALLBACK_MODE_JUST_PAY, i == 0 ? msg.sender : address(this), params.tokens[i]);
      (int128 amount0Delta, int128 amount1Delta) = IMetricOmmPoolActions(pool)
        .swap(
          i == last ? params.recipient : address(this),
          zeroForOne,
          amount,
          MetricOmmSwapPath.openLimit(zeroForOne),
          "",
          params.extensionDatas[i]
        );

      int128 amountInActual = MetricOmmSwapResults.extractAmountIn(zeroForOne, amount0Delta, amount1Delta);
      if (amountInActual < amount) revert InvalidInputAmountAtHop(uint8(i), amountInActual, amount);

      amount = MetricOmmSwapResults.extractAmountOut(zeroForOne, amount0Delta, amount1Delta);
    }

    if (amount <= 0) revert InvalidSwapDeltas();
    amountOut = MetricOmmSwapInputs.int128ToUint128(amount);
    if (amountOut < params.amountOutMinimum) revert InsufficientOutput(amountOut, params.amountOutMinimum);

    _clearExpectedCallbackPool();
  }

  // ============ External: exact output ============

  /// @inheritdoc IMetricOmmSimpleRouter
  function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
    _checkDeadline(params.deadline);
    uint128 priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(params.zeroForOne, params.priceLimitX64);

    int128 expectedAmountOut = MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountOut);
    _setNextCallbackContext(params.pool, CALLBACK_MODE_JUST_PAY, msg.sender, params.tokenIn);
    (int128 amount0Delta, int128 amount1Delta) = IMetricOmmPoolActions(params.pool)
      .swap(params.recipient, params.zeroForOne, -expectedAmountOut, priceLimitX64, "", params.extensionData);
    int128 amountOut = MetricOmmSwapResults.extractAmountOut(params.zeroForOne, amount0Delta, amount1Delta);
    if (amountOut != expectedAmountOut) revert InvalidOutputAmount(amountOut, params.amountOut);

    amountIn = MetricOmmSwapInputs.int128ToUint128(
      MetricOmmSwapResults.extractAmountIn(params.zeroForOne, amount0Delta, amount1Delta)
    );

    if (amountIn > params.amountInMaximum) revert InputTooHigh(amountIn, params.amountInMaximum);
    _clearExpectedCallbackPool();
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Starts at `pools[last]` with a negative `amountSpecified` for the final output token. Remaining hops run
  ///      recursively inside `metricOmmSwapCallback`: each callback pays the current hop's input, then (unless on
  ///      the last pool) swaps the next pool for exactly that input amount. The first swap's input delta is total
  ///      `amountIn`.
  function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn) {
    _checkDeadline(params.deadline);
    _validatePath(params.tokens, params.pools, params.extensionDatas);

    uint8 tradesLeftAfterThis = uint8(params.pools.length - 1);
    address pool = params.pools[tradesLeftAfterThis];
    bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, tradesLeftAfterThis);
    int128 expectedAmountOut = MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountOut);
    _initCallbackContextforRecursiveOutput(
      pool, CALLBACK_MODE_EXACT_OUTPUT_ITERATE, tradesLeftAfterThis, msg.sender, params.tokens[0]
    );
    (int128 amount0Delta, int128 amount1Delta) = IMetricOmmPoolActions(pool)
      .swap(
        params.recipient,
        zeroForOne,
        -expectedAmountOut,
        MetricOmmSwapPath.openLimit(zeroForOne),
        abi.encode(
          ExactOutputIterateCallbackData({
          tokens: params.tokens,
          pools: params.pools,
          extensionDatas: params.extensionDatas,
          zeroForOneBitMap: params.zeroForOneBitMap,
          amountInMax: params.amountInMaximum
        })
        ),
        params.extensionDatas[tradesLeftAfterThis]
      );

    int128 amountOut = MetricOmmSwapResults.extractAmountOut(zeroForOne, amount0Delta, amount1Delta);
    if (amountOut != expectedAmountOut) revert InvalidOutputAmount(amountOut, params.amountOut);

    amountIn = _getExactOutputAmountIn();
    _clearExpectedCallbackPool();
  }

  // ============ Internal: callback handlers ============

  function _justPayCallback(int256 amount0Delta, int256 amount1Delta) private {
    pay(
      _getTokenToPay(),
      _getPayer(),
      msg.sender,
      uint256(MetricOmmSwapResults.extractPositiveAmount(amount0Delta, amount1Delta))
    );
  }

  function _exactOutputIterateCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) private {
    ExactOutputIterateCallbackData memory cb = abi.decode(data, (ExactOutputIterateCallbackData));

    int256 amountToPay = MetricOmmSwapResults.extractPositiveAmount(amount0Delta, amount1Delta);
    uint8 tradesLeft = _getTradesLeft();

    if (tradesLeft == 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 amountIn = uint256(amountToPay);
      if (amountIn > cb.amountInMax) revert InputTooHigh(amountIn, cb.amountInMax);
      _setExactOutputAmountIn(amountIn);
      pay(_getTokenToPay(), _getPayer(), msg.sender, amountIn);
      return;
    }
    tradesLeft--;
    address pool = cb.pools[tradesLeft];
    bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(cb.zeroForOneBitMap, tradesLeft);
    _updateCallbackContextforRecursiveOutput(pool, tradesLeft);

    (int128 amount0DeltaReturned, int128 amount1DeltaReturned) = IMetricOmmPoolActions(pool)
      .swap(
        msg.sender,
        zeroForOne,
        MetricOmmSwapInputs.asAmountSpecifiedFromPositive(amountToPay),
        MetricOmmSwapPath.openLimit(zeroForOne),
        data,
        cb.extensionDatas[tradesLeft]
      );

    int128 amountOut = MetricOmmSwapResults.extractAmountOut(zeroForOne, amount0DeltaReturned, amount1DeltaReturned);

    if (amountOut != amountToPay) revert InvalidOutputAmountAtHop(tradesLeft, amountOut, amountToPay);
  }

  function _validatePath(address[] calldata tokens, address[] calldata pools, bytes[] calldata extensionDatas)
    internal
    pure
  {
    if (
      tokens.length < 2 || pools.length != tokens.length - 1 || extensionDatas.length != pools.length
        || pools.length > MAX_PATH_POOLS
    ) {
      revert InvalidPath();
    }
  }
}
