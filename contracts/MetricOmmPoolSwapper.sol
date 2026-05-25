// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {MetricOmmPoolQuoter} from "./common/MetricOmmPoolQuoter.sol";
import {IMetricOmmPoolSwapper} from "./interfaces/IMetricOmmPoolSwapper.sol";

/// @title MetricOmmPoolSwapper
/// @notice Executes swaps through MetricOmm pools with callback settlement and native ETH paths.
/// @dev Implements callback settlement and transient-context guarded swap orchestration.
///      Uses transient storage (EIP-1153) for swap context.
/// @dev Price-limit sentinel semantics:
///      - `zeroForOne == true`: `priceLimitX64 == 0` means unconstrained lower bound.
///      - `zeroForOne == false`: `priceLimitX64 == type(uint128).max` means unconstrained upper bound.
///      Opposite sentinels are rejected with `InvalidPriceLimitForDirection`.
contract MetricOmmPoolSwapper is IMetricOmmPoolSwapper, MetricOmmPoolQuoter {
  using SafeERC20 for IERC20;

  // ============ Constants ============

  // Transient (EIP-1153) swap context for the current swap.
  // Stored via TSTORE/TLOAD and cleared explicitly to allow multiple swaps in a single transaction.
  uint256 private constant T_SLOT_SWAP_PAYER = 0;
  uint256 private constant T_SLOT_SWAP_POOL = 1;
  uint256 private constant T_SLOT_SWAP_FLAGS = 2;

  uint256 private constant FLAG_PAYER_IS_NATIVE = 1 << 0;
  uint256 private constant FLAG_ZERO_FOR_ONE = 1 << 1;
  uint256 private constant FLAG_EXPECT_NATIVE_OUTPUT = 1 << 2;
  uint128 private constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  // ============ State Variables ============

  address internal immutable WETH;

  // ============ Constructor ============

  constructor(address weth) {
    if (weth == address(0)) revert InvalidWETH();
    WETH = weth;
  }

  // ============ External: lifecycle ============

  /// @notice Accept raw ETH only from WETH withdraws
  receive() external payable {
    if (msg.sender != WETH) revert NativeTransferFailed();
  }

  // ============ External: spot swap ============

  /// @notice Execute a swap on a pool (simple version without data)
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline
  ) public payable override returns (int128 amount0Delta, int128 amount1Delta) {
    return swap(pool, recipient, zeroForOne, amountSpecified, priceLimitX64, deadline, "");
  }

  // ============ External: token swap ============

  /// @notice Execute a swap on a pool with custom callback data
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline,
    bytes memory data
  ) public payable override returns (int128 amount0Delta, int128 amount1Delta) {
    _checkDeadline(deadline);
    if (msg.value != 0) revert NativeValueNotExpected();
    (amount0Delta, amount1Delta) =
      _swapWithContext(pool, msg.sender, recipient, zeroForOne, amountSpecified, priceLimitX64, false, false, data);
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
  ) external payable override returns (uint256 amountOut, uint256 amountInUsed) {
    if (msg.value != 0) revert NativeValueNotExpected();
    (int128 amount0Delta, int128 amount1Delta) =
      swap(pool, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, deadline, "");
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
  }

  // ============ External: native <-> token swap ============

  /// @notice Swap with exact output amount and maximum input limit
  function swapExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable override returns (uint256 amountOut, uint256 amountInUsed) {
    if (msg.value != 0) revert NativeValueNotExpected();
    (int128 amount0Delta, int128 amount1Delta) =
      swap(pool, recipient, zeroForOne, _toSignedExactOutput(amountOutDesired), priceLimitX64, deadline, "");
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
  ) external payable override returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);
    if (msg.value != uint256(amountIn)) revert InsufficientNativeValue(amountIn, msg.value);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool, msg.sender, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, true, false, ""
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
  ) external payable override returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);
    if (msg.value != maxAmountIn) revert InsufficientNativeValue(maxAmountIn, msg.value);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool, msg.sender, recipient, zeroForOne, _toSignedExactOutput(amountOutDesired), priceLimitX64, true, false, ""
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
  ) external override returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool, msg.sender, address(this), zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, false, true, ""
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
  ) external override returns (uint256 amountOut, uint256 amountInUsed) {
    _checkDeadline(deadline);

    (int128 amount0Delta, int128 amount1Delta) = _swapWithContext(
      pool,
      msg.sender,
      address(this),
      zeroForOne,
      _toSignedExactOutput(amountOutDesired),
      priceLimitX64,
      false,
      true,
      ""
    );
    (amountInUsed, amountOut) = _decodeSwapResult(zeroForOne, amount0Delta, amount1Delta);

    if (amountOut < amountOutDesired) revert InvalidSwapDeltas();
    if (amountInUsed > maxAmountIn) revert InputTooHigh(amountInUsed, maxAmountIn);
    _unwrapAndSendNative(recipient, amountOut);
    _clearSwap();
  }

  // ============ External: callback settlement ============

  /// @notice Callback invoked by pool during swap execution to settle input leg.
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    (address payer, address pool, uint256 flags) = _loadSwapContext();
    if (msg.sender != pool) revert InvalidCallbackCaller();

    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    address token0 = imm.token0;
    address token1 = imm.token1;

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

  // ============ Internal: swap orchestration ============

  function _startSwap(address pool, address payer, bool payerIsNative, bool expectNativeOutput, bool zeroForOne)
    private
  {
    (, address currentPool,) = _loadSwapContext();
    if (currentPool != address(0)) revert SwapInProgress();

    uint256 flags = (payerIsNative ? FLAG_PAYER_IS_NATIVE : 0) | (zeroForOne ? FLAG_ZERO_FOR_ONE : 0)
      | (expectNativeOutput ? FLAG_EXPECT_NATIVE_OUTPUT : 0);
    _setSwapContext(payer, pool, flags);
  }

  function _clearSwap() private {
    _clearSwapContext();
  }

  function _swapWithContext(
    address pool,
    address payer,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bool payerIsNative,
    bool expectNativeOutput,
    bytes memory data
  ) private returns (int128 amount0Delta, int128 amount1Delta) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    _startSwap(pool, payer, payerIsNative, expectNativeOutput, zeroForOne);

    try IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, data) returns (
      int128 a0, int128 a1
    ) {
      amount0Delta = a0;
      amount1Delta = a1;
      _validateAmountSpecifiedMatch(zeroForOne, amountSpecified, amount0Delta, amount1Delta);
    } catch (bytes memory reason) {
      _clearSwap();
      assembly {
        revert(add(reason, 32), mload(reason))
      }
    }

    // Leave transient context intact for post-swap settlement (caller clears).
  }

  // ============ Internal: settlement and native handling ============

  function _payInput(address token, uint256 amount, address payer, address pool, bool payerIsNative) private {
    if (!payerIsNative) {
      IERC20(token).safeTransferFrom(payer, pool, amount);
      return;
    }

    if (token != WETH) revert NativeInputNotSupported(token);
    if (address(this).balance < amount) revert InsufficientNativeValue(amount, address(this).balance);

    IWETH9(WETH).deposit{value: amount}();
    IERC20(WETH).safeTransfer(pool, amount);
  }

  function _checkDeadline(uint256 deadline) private view {
    // forge-lint: disable-next-line(block-timestamp)
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

  // ============ Internal: validation and decoding ============

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

  function _validateAmountSpecifiedMatch(
    bool zeroForOne,
    int128 amountSpecified,
    int128 amount0Delta,
    int128 amount1Delta
  ) private pure {
    if (amountSpecified == 0) {
      if (amount0Delta != 0 || amount1Delta != 0) {
        revert AmountSpecifiedMismatch(0, amount0Delta != 0 ? amount0Delta : amount1Delta);
      }
      return;
    }

    int128 actual =
      amountSpecified > 0 ? (zeroForOne ? amount0Delta : amount1Delta) : (zeroForOne ? amount1Delta : amount0Delta);
    if (amountSpecified > 0) {
      if (actual <= 0 || actual > amountSpecified) revert AmountSpecifiedMismatch(amountSpecified, actual);
      return;
    }
    if (actual >= 0 || actual < amountSpecified) revert AmountSpecifiedMismatch(amountSpecified, actual);
  }

  function _validatePriceLimit(bool zeroForOne, uint128 priceLimitX64) private pure {
    if (zeroForOne) {
      if (priceLimitX64 == type(uint128).max) revert InvalidPriceLimitForDirection(true, priceLimitX64);
      return;
    }
    if (priceLimitX64 == 0) revert InvalidPriceLimitForDirection(false, priceLimitX64);
  }

  function _toSignedExactInput(uint128 amountIn) private pure returns (int128 amountSpecified) {
    if (amountIn > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountIn);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = int128(amountIn);
  }

  function _toSignedExactOutput(uint128 amountOutDesired) private pure returns (int128 amountSpecified) {
    if (amountOutDesired > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountOutDesired);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = -int128(amountOutDesired);
  }

  // ============ Internal: transient context storage ============

  function _setSwapContext(address payer, address pool, uint256 flags) private {
    _tstoreAddress(T_SLOT_SWAP_PAYER, payer);
    _tstoreAddress(T_SLOT_SWAP_POOL, pool);
    _tstore(T_SLOT_SWAP_FLAGS, flags);
  }

  function _clearSwapContext() private {
    _tstoreAddress(T_SLOT_SWAP_PAYER, address(0));
    _tstoreAddress(T_SLOT_SWAP_POOL, address(0));
    _tstore(T_SLOT_SWAP_FLAGS, 0);
  }

  function _loadSwapContext() private view returns (address payer, address pool, uint256 flags) {
    payer = _tloadAddress(T_SLOT_SWAP_PAYER);
    pool = _tloadAddress(T_SLOT_SWAP_POOL);
    flags = _tload(T_SLOT_SWAP_FLAGS);
  }

  function _tload(uint256 slot) private view returns (uint256 value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  function _tstore(uint256 slot, uint256 value) private {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  function _tloadAddress(uint256 slot) private view returns (address value) {
    // forge-lint: disable-next-line(unsafe-typecast)
    value = address(uint160(_tload(slot)));
  }

  function _tstoreAddress(uint256 slot, address value) private {
    _tstore(slot, uint256(uint160(value)));
  }
}
