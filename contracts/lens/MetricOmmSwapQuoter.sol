// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title MetricOmmSwapQuoter
/// @notice Quotes swaps by calling pool.swap and reverting in the callback with net deltas.
/// @dev For off-chain queries only (eth_call). Callback revert rolls back swap state and token transfers.
contract MetricOmmSwapQuoter is IMetricOmmSwapCallback {
  uint128 private constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  /// @notice Deliberate revert carrying swap deltas from the callback.
  error QuoteSwapResult(int256 amount0Delta, int256 amount1Delta);
  /// @notice Wrapped downstream revert from the pool swap path.
  error WrappedError(address target, bytes4 selector, bytes reason);
  /// @notice pool.swap completed without callback revert.
  error QuoteDidNotRevert();
  /// @notice Provided unsigned amount does not fit in int128.
  error AmountTooLarge(uint128 amount);
  /// @notice Deltas do not match expected exact-in/out shape.
  error InvalidSwapDeltas();
  /// @notice Price-limit sentinel invalid for swap direction.
  error InvalidPriceLimitForDirection(bool zeroForOne, uint128 priceLimitX64);

  // ============ External: quotes ============

  /// @notice Quote exact-input swap using live pool prices.
  function quoteSwapExactIn(address pool, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteSwapExactIn(pool, address(this), zeroForOne, amountIn, priceLimitX64, hex"");
  }

  /// @notice Quote exact-input swap with explicit recipient and extension context.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteSwapExactIn(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteSwap(pool, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, extensionData);
    return _decodeSwapAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  /// @notice Quote exact-output swap using live pool prices.
  function quoteSwapExactOut(address pool, bool zeroForOne, uint128 amountOutDesired, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteSwapExactOut(pool, address(this), zeroForOne, amountOutDesired, priceLimitX64, hex"");
  }

  /// @notice Quote exact-output swap with explicit recipient and extension context.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteSwapExactOut(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteSwap(pool, recipient, zeroForOne, _toSignedExactOutput(amountOutDesired), priceLimitX64, extensionData);
    return _decodeSwapAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  // ============ External: callback ============

  /// @inheritdoc IMetricOmmSwapCallback
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    revert QuoteSwapResult(amount0Delta, amount1Delta);
  }

  // ============ Internal: quote orchestration ============

  function _quoteSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPoolActions(pool)
      .swap(recipient, zeroForOne, amountSpecified, priceLimitX64, hex"", extensionData) returns (
      int128, int128
    ) {
      revert QuoteDidNotRevert();
    } catch (bytes memory reason) {
      return _decodeQuoteResult(reason, pool);
    }
  }

  function _decodeQuoteResult(bytes memory reason, address pool)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) == QuoteSwapResult.selector) {
      int256 a0;
      int256 a1;
      assembly ("memory-safe") {
        a0 := mload(add(reason, 36))
        a1 := mload(add(reason, 68))
      }
      // forge-lint: disable-next-line(unsafe-typecast)
      amount0Delta = int128(a0);
      // forge-lint: disable-next-line(unsafe-typecast)
      amount1Delta = int128(a1);
      return (amount0Delta, amount1Delta);
    }
    revert WrappedError(pool, IMetricOmmPoolActions.swap.selector, reason);
  }

  function _decodeSwapAmounts(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    internal
    pure
    returns (uint256 amountIn, uint256 amountOut)
  {
    if (zeroForOne) {
      if (amount0Delta <= 0 || amount1Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint256(uint128(amount0Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint256(uint128(-amount1Delta));
    } else {
      if (amount1Delta <= 0 || amount0Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint256(uint128(amount1Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint256(uint128(-amount0Delta));
    }
  }

  function _validatePriceLimit(bool zeroForOne, uint128 priceLimitX64) internal pure {
    if (zeroForOne) {
      if (priceLimitX64 == type(uint128).max) revert InvalidPriceLimitForDirection(true, priceLimitX64);
      return;
    }
    if (priceLimitX64 == 0) revert InvalidPriceLimitForDirection(false, priceLimitX64);
  }

  function _toSignedExactInput(uint128 amountIn) internal pure returns (int128 amountSpecified) {
    if (amountIn > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountIn);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = int128(amountIn);
  }

  function _toSignedExactOutput(uint128 amountOutDesired) internal pure returns (int128 amountSpecified) {
    if (amountOutDesired > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountOutDesired);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = -int128(amountOutDesired);
  }
}
