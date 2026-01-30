// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "./interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {MetricOmmPoolQuoter} from "./MetricOmmPoolQuoter.sol";
import {WrappedERC20} from "./libraries/WrappedERC20.sol";

/// @title MetricOmmSwapRouter
/// @notice Router contract for executing swaps through MetricOmm pools
/// @dev Implements IMetricOmmSwapCallback to handle the callback pattern.
///      Uses transient storage (EIP-1153) for swap context.
contract MetricOmmSwapRouter is IMetricOmmSwapCallback, MetricOmmPoolQuoter {
  using WrappedERC20 for address;
  using SafeCast for uint256;
  using SafeCast for int256;

  address internal immutable WETH;

  // Transient (EIP-1153) swap context for the current swap.
  // Stored via TSTORE/TLOAD and cleared explicitly to allow multiple swaps in a single transaction.
  uint256 private constant T_SLOT_PAYER = 0;
  uint256 private constant T_SLOT_POOL = 1;
  uint256 private constant T_SLOT_FLAGS = 2;

  uint256 private constant FLAG_PAYER_IS_NATIVE = 1 << 0;
  uint256 private constant FLAG_ZERO_FOR_ONE = 1 << 1;
  uint256 private constant FLAG_EXPECT_NATIVE_OUTPUT = 1 << 2;

  error TransactionExpired(uint256 deadline, uint256 timestamp);
  error InvalidCallbackCaller();
  error SwapInProgress();
  error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
  error InputTooHigh(uint256 amountIn, uint256 maxAmountIn);
  error InvalidSwapDeltas();
  error InvalidWETH();
  error NativeValueNotExpected();
  error NativeInputNotSupported(address token);
  error InsufficientNativeValue(uint256 required, uint256 available);
  error NativeTransferFailed();
  error NativeOutputNotSupported(address token);

  constructor(address _weth) {
    if (_weth == address(0)) revert InvalidWETH();
    WETH = _weth;
  }

  /// @notice Accept raw ETH only from WETH withdraws
  receive() external payable {
    if (msg.sender != WETH) revert NativeTransferFailed();
  }

  /// @notice Execute a swap on a pool (simple version without data)
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline
  ) public payable returns (int128 amount0Delta, int128 amount1Delta) {
    return swap(pool, recipient, zeroForOne, amountSpecified, priceLimitX64, deadline, "");
  }

  /// @notice Execute a swap on a pool with custom callback data
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline,
    bytes memory data
  ) public payable returns (int128 amount0Delta, int128 amount1Delta) {
    _checkDeadline(deadline);
    if (msg.value != 0) revert NativeValueNotExpected();

    _startSwap(pool, msg.sender, false, false, zeroForOne);

    try IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, data) returns (
      int128 a0, int128 a1
    ) {
      amount0Delta = a0;
      amount1Delta = a1;
    } catch (bytes memory reason) {
      _clearSwap();
      assembly {
        revert(add(reason, 32), mload(reason))
      }
    }

    _clearSwap();
  }

  /// @notice Swap with exact input amount and minimum output guarantee
  function swapExactInput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
    if (msg.value != 0) revert NativeValueNotExpected();
    (int128 amount0Delta, int128 amount1Delta) = swap(
      pool,
      recipient,
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      int128(amountIn),
      priceLimitX64,
      deadline,
      ""
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
  }

  /// @notice Swap with exact output amount and maximum input limit
  function swapExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
    if (msg.value != 0) revert NativeValueNotExpected();
    (int128 amount0Delta, int128 amount1Delta) = swap(
      pool,
      recipient,
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      -int128(amountOutDesired),
      priceLimitX64,
      deadline,
      ""
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < amountOutDesired) revert InvalidSwapDeltas();
    if (amountInUsed > maxAmountIn) revert InputTooHigh(amountInUsed, maxAmountIn);
  }

  /// @notice Swap native ETH for tokens (exact input)
  function swapExactInputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);
    if (msg.value != uint256(amountIn)) revert InsufficientNativeValue(amountIn, msg.value);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool,
      msg.sender,
      recipient,
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      int128(amountIn),
      priceLimitX64,
      true,
      false
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
    _refundUnusedNative(msg.sender, msg.value, amountInUsed);
    _clearSwap();
  }

  /// @notice Swap native ETH for tokens (exact output)
  function swapExactOutputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);
    if (msg.value != maxAmountIn) revert InsufficientNativeValue(maxAmountIn, msg.value);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool,
      msg.sender,
      recipient,
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      -int128(amountOutDesired),
      priceLimitX64,
      true,
      false
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < amountOutDesired) revert InvalidSwapDeltas();
    if (amountInUsed > maxAmountIn) revert InputTooHigh(amountInUsed, maxAmountIn);
    _refundUnusedNative(msg.sender, msg.value, amountInUsed);
    _clearSwap();
  }

  /// @notice Swap tokens for native ETH (exact input)
  function swapExactInputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool,
      msg.sender,
      address(this),
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      int128(amountIn),
      priceLimitX64,
      false,
      true
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
    _unwrapAndSendNative(recipient, amountOut);
    _clearSwap();
  }

  /// @notice Swap tokens for native ETH (exact output)
  function swapExactOutputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool,
      msg.sender,
      address(this),
      zeroForOne,
      // forge-lint: disable-next-line(unsafe-typecast)
      -int128(amountOutDesired),
      priceLimitX64,
      false,
      true
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < amountOutDesired) revert InvalidSwapDeltas();
    if (amountInUsed > maxAmountIn) revert InputTooHigh(amountInUsed, maxAmountIn);
    _unwrapAndSendNative(recipient, amountOut);
    _clearSwap();
  }

  /// @notice Callback invoked by the pool during swap execution
  /// @inheritdoc IMetricOmmSwapCallback
  function metricOmmSwapCallback(
    address token0,
    address token1,
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata
  ) external {
    (address payer, address pool, uint256 flags) = _loadSwapContext();
    if (msg.sender != pool) revert InvalidCallbackCaller();

    bool zeroForOne = (flags & FLAG_ZERO_FOR_ONE) != 0;
    bool payerIsNative = (flags & FLAG_PAYER_IS_NATIVE) != 0;
    bool expectNativeOutput = (flags & FLAG_EXPECT_NATIVE_OUTPUT) != 0;

    if (expectNativeOutput) {
      address outputToken = zeroForOne ? token1 : token0;
      if (outputToken != WETH) revert NativeOutputNotSupported(outputToken);
    }

    if (payerIsNative && amount0Delta > 0 && amount1Delta > 0) revert InvalidSwapDeltas();

    if (amount0Delta > 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      _payInput(token0, uint256(amount0Delta), payer, pool, payerIsNative);
    }
    if (amount1Delta > 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      _payInput(token1, uint256(amount1Delta), payer, pool, payerIsNative);
    }
  }

  // ============ Internal Functions ============

  function _startSwap(address pool, address payer, bool payerIsNative, bool expectNativeOutput, bool zeroForOne)
    private
  {
    (, address currentPool,) = _loadSwapContext();
    if (currentPool != address(0)) revert SwapInProgress();

    uint256 flags = (payerIsNative ? FLAG_PAYER_IS_NATIVE : 0) | (zeroForOne ? FLAG_ZERO_FOR_ONE : 0)
      | (expectNativeOutput ? FLAG_EXPECT_NATIVE_OUTPUT : 0);
    assembly ("memory-safe") {
      tstore(T_SLOT_PAYER, payer)
      tstore(T_SLOT_POOL, pool)
      tstore(T_SLOT_FLAGS, flags)
    }
  }

  function _clearSwap() private {
    assembly ("memory-safe") {
      tstore(T_SLOT_PAYER, 0)
      tstore(T_SLOT_POOL, 0)
      tstore(T_SLOT_FLAGS, 0)
    }
  }

  function _swapWithContext(
    address pool,
    address payer,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bool payerIsNative,
    bool expectNativeOutput
  ) private returns (int128 amount0Delta, int128 amount1Delta) {
    _startSwap(pool, payer, payerIsNative, expectNativeOutput, zeroForOne);

    try IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, "") returns (
      int128 a0, int128 a1
    ) {
      amount0Delta = a0;
      amount1Delta = a1;
    } catch (bytes memory reason) {
      _clearSwap();
      assembly {
        revert(add(reason, 32), mload(reason))
      }
    }

    // Leave transient context intact for post-swap settlement (caller clears).
  }

  function _payInput(address token, uint256 amount, address payer, address pool, bool payerIsNative) private {
    if (!payerIsNative) {
      token.safeTransferFrom(payer, pool, amount);
      return;
    }

    if (token != WETH) revert NativeInputNotSupported(token);
    if (address(this).balance < amount) revert InsufficientNativeValue(amount, address(this).balance);

    IWETH9(WETH).deposit{value: amount}();
    WETH.safeTransfer(pool, amount);
  }

  function _loadSwapContext() private view returns (address payer, address pool, uint256 flags) {
    assembly ("memory-safe") {
      payer := tload(T_SLOT_PAYER)
      pool := tload(T_SLOT_POOL)
      flags := tload(T_SLOT_FLAGS)
    }
  }

  function _checkDeadline(uint256 deadline) private view {
    if (block.timestamp > deadline) revert TransactionExpired(deadline, block.timestamp);
  }

  function _refundUnusedNative(address to, uint256 maxAmountIn, uint256 amountInUsed) private {
    if (amountInUsed > maxAmountIn) revert InputTooHigh(amountInUsed, maxAmountIn);
    uint256 refund = maxAmountIn - amountInUsed;
    if (refund == 0) return;
    (bool ok,) = to.call{value: refund}("");
    if (!ok) revert NativeTransferFailed();
  }

  function _unwrapAndSendNative(address to, uint256 amountOut) private {
    IWETH9(WETH).withdraw(amountOut);
    (bool ok,) = to.call{value: amountOut}("");
    if (!ok) revert NativeTransferFailed();
  }

  function _decodeSwapResult(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    private
    pure
    returns (uint256 amountIn, uint256 amountOut)
  {
    if (zeroForOne) {
      if (amount0Delta <= 0 || amount1Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint128(amount0Delta);
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint128(-amount1Delta);
    } else {
      if (amount1Delta <= 0 || amount0Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint128(amount1Delta);
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint128(-amount0Delta);
    }
  }
}
