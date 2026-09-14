// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MetricOmmSwapRouterBase} from "./base/MetricOmmSwapRouterBase.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {SelfPermit} from "./base/SelfPermit.sol";
import {IMetricOmmSimpleRouter} from "./interfaces/IMetricOmmSimpleRouter.sol";
import {IPeripheryPayments} from "./interfaces/IPeripheryPayments.sol";
import {IMulticall} from "./interfaces/IMulticall.sol";
import {MetricOmmSwapPath} from "./libraries/MetricOmmSwapPath.sol";
import {MetricOmmSwapInputs} from "./libraries/MetricOmmSwapInputs.sol";
import {MetricOmmSwapResults} from "./libraries/MetricOmmSwapResults.sol";

/// @title MetricOmmSimpleRouter
/// @notice Exact-input and exact-output swaps through one or more MetricOmm pools.
/// @dev Expected callback pool, payer, token, and swap mode are stored in transient storage at entry.
///      Swaps, payments, and permit calls share a transient execution lock inherited through SelfPermit.
///      Primary and fallback attempts run inside the outer swap lock, including across caught reverts.

contract MetricOmmSimpleRouter is MetricOmmSwapRouterBase, PeripheryPayments, SelfPermit, IMetricOmmSimpleRouter {
  using SafeERC20 for IERC20;

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
    // Each delegated operation acquires and releases the shared lock. Reject nested entry
    // during an operation, but do not lock the dispatcher itself.
    if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
    results = new bytes[](data.length);
    for (uint256 i = 0; i < data.length; i++) {
      results[i] = Address.functionDelegateCall(address(this), data[i]);
    }
  }

  /// @inheritdoc IPeripheryPayments
  function unwrapWETH9(uint256 amountMinimum, address recipient)
    public
    payable
    override(PeripheryPayments, IPeripheryPayments)
    nonReentrant
  {
    super.unwrapWETH9(amountMinimum, recipient);
  }

  /// @inheritdoc IPeripheryPayments
  function sweepToken(address token, uint256 amountMinimum, address recipient)
    public
    payable
    override(PeripheryPayments, IPeripheryPayments)
    nonReentrant
  {
    super.sweepToken(token, amountMinimum, recipient);
  }

  /// @inheritdoc IPeripheryPayments
  function refundETH() public payable override(PeripheryPayments, IPeripheryPayments) nonReentrant {
    super.refundETH();
  }

  // Callbacks and OnlySelf attempt entrypoints deliberately do not acquire the lock again.
  // They authenticate the expected pool or this router while the outer swap retains the lock.
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
  function exactInputSingle(ExactInputSingleParams calldata params)
    external
    payable
    nonReentrant
    returns (uint256 amountOut)
  {
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
  function exactInput(ExactInputParams calldata params) external payable nonReentrant returns (uint256 amountOut) {
    amountOut = _exactInput(params, msg.sender);
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Attempts `primary`, and calls `params.fallbackRouter` only if it reverts. Both legs execute as self-calls so a
  ///      failing leg unwinds its own transfers, approvals, and transient callback context (EIP-1153 reverts
  ///      `TSTORE` alongside storage) without taking the transaction with it. `payer` stays the outer `msg.sender`
  ///      for both legs, so funds are pulled from the original caller either way, native ETH included: value sits
  ///      on this contract for the whole call and no value is forwarded to an attempt.
  function exactInputWithFallback(ExactInputWithFallbackParams calldata params)
    external
    payable
    nonReentrant
    returns (uint256 amountOut, bool usedFallback)
  {
    _checkDeadline(params.primary.deadline);
    _validatePath(params.primary.tokens, params.primary.pools, params.primary.extensionDatas);
    if (params.fallbackRouter == address(this) || params.fallbackRouter.code.length == 0) {
      revert InvalidFallbackRouter(params.fallbackRouter);
    }
    if (params.fallbackCallData.length == 0) revert EmptyFallbackCallData();

    // Encode before measuring gas: path size must not eat into the attempt's budget.
    bytes memory attempt = abi.encodeCall(this.exactInputAttempt, (params.primary, msg.sender));
    (bool primarySuccess, bytes memory primaryReason) =
      _primaryAttempt(attempt, params.primaryGasLimit, params.gasReserve);
    if (primarySuccess) {
      return (abi.decode(primaryReason, (uint256)), false);
    } else {
      try this.fallbackSwapAttempt(_fallbackTerms(params, msg.sender), params.fallbackCallData) returns (
        uint256 fallbackOut, uint256
      ) {
        return (fallbackOut, true);
      } catch (bytes memory fallbackReason) {
        revert BothRoutesFailed(primaryReason, fallbackReason);
      }
    }
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Self-call only. Exists so `exactInputWithFallback` can isolate a leg's revert; `payer` is supplied by
  ///      the caller and is never attacker-controlled because only this contract may reach it.
  function exactInputAttempt(ExactInputParams calldata params, address payer) external returns (uint256 amountOut) {
    if (msg.sender != address(this)) revert OnlySelf();
    amountOut = _exactInput(params, payer);
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Self-call only, for the same revert-isolation reason as `exactInputAttempt`. Terms are constructed from
  ///      the public swap parameters, with the original caller as payer and all limits from the primary route.
  function fallbackSwapAttempt(FallbackSwapTerms calldata terms, bytes calldata callData)
    external
    returns (uint256 amountOut, uint256 amountSpent)
  {
    if (msg.sender != address(this)) revert OnlySelf();
    (amountOut, amountSpent) = _fallbackSwap(terms, callData);
  }

  // ============ Internal: exact input ============

  function _exactInput(ExactInputParams calldata params, address payer) internal returns (uint256 amountOut) {
    _checkDeadline(params.deadline);
    _validatePath(params.tokens, params.pools, params.extensionDatas);

    uint256 last = params.pools.length - 1;
    int128 amount = MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountIn);

    for (uint256 i = 0; i <= last; i++) {
      address pool = params.pools[i];
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, i);

      _setNextCallbackContext(pool, CALLBACK_MODE_JUST_PAY, i == 0 ? payer : address(this), params.tokens[i]);
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

  /// @dev Unlike the MetricOmm legs, an external aggregator pulls from its own `msg.sender`, so this router must
  ///      take custody first. Nothing about `callData` is trusted: the approval is capped at `terms.amountIn`, the
  ///      output is the measured balance delta rather than anything the call returns, and whatever input the leg
  ///      did not spend goes back to the payer.
  ///      Side-agnostic: an exact-input leg passes its exact spend as `terms.amountIn` and its minimum as
  ///      `terms.amountOutMinimum`; an exact-output leg passes its maximum spend and its exact output in the same
  ///      two fields. `amountSpent` is what the leg actually consumed, which is the exact-output legs' `amountIn`.
  ///      No value is forwarded to the call, so the leg must be quoted in the wrapped native token, never native.
  ///      Input and output tokens must differ so unspent input cannot be counted as output.
  function _fallbackSwap(FallbackSwapTerms calldata terms, bytes calldata callData)
    internal
    returns (uint256 amountOut, uint256 amountSpent)
  {
    _checkDeadline(terms.deadline);
    if (terms.tokenIn == terms.tokenOut) revert SameTokenFallback();

    IERC20 tokenIn = IERC20(terms.tokenIn);
    IERC20 tokenOut = IERC20(terms.tokenOut);
    uint256 tokenInBefore = tokenIn.balanceOf(address(this));
    uint256 tokenOutBefore = tokenOut.balanceOf(address(this));

    pay(terms.tokenIn, terms.payer, address(this), terms.amountIn);
    tokenIn.forceApprove(terms.fallbackRouter, terms.amountIn);

    _callFallback(terms.fallbackRouter, callData);

    tokenIn.forceApprove(terms.fallbackRouter, 0);

    amountOut = tokenOut.balanceOf(address(this)) - tokenOutBefore;
    if (amountOut < terms.amountOutMinimum) revert InsufficientOutput(amountOut, terms.amountOutMinimum);
    tokenOut.safeTransfer(terms.recipient, amountOut);

    uint256 unspent = tokenIn.balanceOf(address(this)) - tokenInBefore;
    if (unspent > 0) tokenIn.safeTransfer(terms.payer, unspent);
    amountSpent = terms.amountIn - unspent;
  }

  function _fallbackTerms(ExactInputWithFallbackParams calldata params, address payer)
    internal
    pure
    returns (FallbackSwapTerms memory terms)
  {
    terms = FallbackSwapTerms({
      fallbackRouter: params.fallbackRouter,
      tokenIn: params.primary.tokens[0],
      tokenOut: params.primary.tokens[params.primary.tokens.length - 1],
      recipient: params.primary.recipient,
      payer: payer,
      amountIn: params.primary.amountIn,
      amountOutMinimum: params.primary.amountOutMinimum,
      deadline: params.primary.deadline
    });
  }

  /// @dev Exact-output counterpart of `_fallbackTerms`. `amountIn` carries the maximum spend rather than an exact
  ///      one, and `amountOutMinimum` carries the exact output required, which `_fallbackSwap` enforces as a floor.
  ///      An aggregator that delivers exactly `amountOut` therefore clears it, and its unspent input is refunded.
  function _fallbackTermsExactOut(ExactOutputWithFallbackParams calldata params, address payer)
    internal
    pure
    returns (FallbackSwapTerms memory terms)
  {
    terms = FallbackSwapTerms({
      fallbackRouter: params.fallbackRouter,
      tokenIn: params.primary.tokens[0],
      tokenOut: params.primary.tokens[params.primary.tokens.length - 1],
      recipient: params.primary.recipient,
      payer: payer,
      amountIn: params.primary.amountInMaximum,
      amountOutMinimum: params.primary.amountOut,
      deadline: params.primary.deadline
    });
  }

  /// @dev Fixed primary budget prevents estimation from choosing a cheaper primary-OOG/fallback path.
  ///      Keep both the requested reserve and EIP-150's 1/64 in the parent, plus call overhead.
  ///      Cap copied revert data so a failing pool cannot consume the reserve with a return-data bomb.
  function _primaryAttempt(bytes memory data, uint256 primaryGasLimit, uint256 gasReserve)
    private
    returns (bool success, bytes memory result)
  {
    if (primaryGasLimit == 0) revert InvalidPrimaryGasLimit();
    uint256 available = gasleft();
    uint256 overhead = 10_000;
    uint256 retained = primaryGasLimit / 63 + 1;
    if (retained < gasReserve) retained = gasReserve;
    // Subtraction-based checks also reject oversized caller budgets without arithmetic overflow.
    if (
      available <= overhead || primaryGasLimit > available - overhead
        || retained > available - overhead - primaryGasLimit
    ) {
      revert InsufficientGasReserve(gasReserve, available);
    }
    assembly ("memory-safe") {
      success := call(primaryGasLimit, address(), 0, add(data, 0x20), mload(data), 0, 0)
      let size := returndatasize()
      if gt(size, 4096) { size := 4096 }
      result := mload(0x40)
      mstore(result, size)
      returndatacopy(add(result, 0x20), 0, size)
      mstore(0x40, and(add(add(result, size), 0x3f), not(0x1f)))
    }
  }

  /// @dev Successful return data is unused. Only copy a bounded failure diagnostic so the
  ///      external target cannot force an unbounded allocation in this call frame.
  function _callFallback(address target, bytes memory data) private {
    bool success;
    bytes memory reason;
    assembly ("memory-safe") {
      success := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
      if iszero(success) {
        let size := returndatasize()
        if gt(size, 4096) { size := 4096 }
        reason := mload(0x40)
        mstore(reason, size)
        returndatacopy(add(reason, 0x20), 0, size)
        mstore(0x40, and(add(add(reason, size), 0x3f), not(0x1f)))
      }
    }
    if (!success) _bubbleRevert(reason);
  }

  /// @dev Re-reverts the bounded fallback reason so it survives into `BothRoutesFailed`.
  function _bubbleRevert(bytes memory reason) private pure {
    if (reason.length == 0) revert FallbackCallFailed();
    assembly ("memory-safe") {
      revert(add(reason, 0x20), mload(reason))
    }
  }

  // ============ External: exact output ============

  /// @inheritdoc IMetricOmmSimpleRouter
  function exactOutputSingle(ExactOutputSingleParams calldata params)
    external
    payable
    nonReentrant
    returns (uint256 amountIn)
  {
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
  function exactOutput(ExactOutputParams calldata params) external payable nonReentrant returns (uint256 amountIn) {
    amountIn = _exactOutput(params, msg.sender);
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Exact-output counterpart of `exactInputWithFallback`, with the same isolation model: both legs execute as
  ///      self-calls so a failing leg unwinds its own transfers, approvals, and transient callback context without
  ///      taking the transaction with it, and `payer` stays the outer `msg.sender` for both legs.
  ///      The fallback leg's spend is what it actually consumed, not `primary.amountInMaximum`; the remainder is
  ///      refunded to the payer inside the leg.
  function exactOutputWithFallback(ExactOutputWithFallbackParams calldata params)
    external
    payable
    nonReentrant
    returns (uint256 amountIn, bool usedFallback)
  {
    _checkDeadline(params.primary.deadline);
    _validatePath(params.primary.tokens, params.primary.pools, params.primary.extensionDatas);
    if (params.fallbackRouter == address(this) || params.fallbackRouter.code.length == 0) {
      revert InvalidFallbackRouter(params.fallbackRouter);
    }
    if (params.fallbackCallData.length == 0) revert EmptyFallbackCallData();

    // Encode before measuring gas: path size must not eat into the attempt's budget.
    bytes memory attempt = abi.encodeCall(this.exactOutputAttempt, (params.primary, msg.sender));
    (bool primarySuccess, bytes memory primaryReason) =
      _primaryAttempt(attempt, params.primaryGasLimit, params.gasReserve);
    if (primarySuccess) {
      return (abi.decode(primaryReason, (uint256)), false);
    } else {
      try this.fallbackSwapAttempt(_fallbackTermsExactOut(params, msg.sender), params.fallbackCallData) returns (
        uint256, uint256 fallbackIn
      ) {
        return (fallbackIn, true);
      } catch (bytes memory fallbackReason) {
        revert BothRoutesFailed(primaryReason, fallbackReason);
      }
    }
  }

  /// @inheritdoc IMetricOmmSimpleRouter
  /// @dev Self-call only, for the same revert-isolation reason as `exactInputAttempt`. `payer` is supplied by the
  ///      caller and is never attacker-controlled because only this contract may reach it.
  function exactOutputAttempt(ExactOutputParams calldata params, address payer) external returns (uint256 amountIn) {
    if (msg.sender != address(this)) revert OnlySelf();
    amountIn = _exactOutput(params, payer);
  }

  // ============ Internal: exact output ============

  function _exactOutput(ExactOutputParams calldata params, address payer) internal returns (uint256 amountIn) {
    _checkDeadline(params.deadline);
    _validatePath(params.tokens, params.pools, params.extensionDatas);

    uint8 tradesLeftAfterThis = uint8(params.pools.length - 1);
    address pool = params.pools[tradesLeftAfterThis];
    bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, tradesLeftAfterThis);
    int128 expectedAmountOut = MetricOmmSwapInputs.asAmountSpecifiedIn(params.amountOut);
    _initCallbackContextforRecursiveOutput(
      pool, CALLBACK_MODE_EXACT_OUTPUT_ITERATE, tradesLeftAfterThis, payer, params.tokens[0]
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
