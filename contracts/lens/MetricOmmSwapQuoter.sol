// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title MetricOmmSwapQuoter
/// @notice Off-chain swap quotes: live oracle prices via pool.swap, or hypothetical prices via simulateSwapAndRevert.
/// @dev For off-chain queries only (eth_call). Live quotes revert in the swap callback; hypothetical quotes decode SimulateSwap.
contract MetricOmmSwapQuoter is IMetricOmmSwapCallback {
  uint128 private constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  /// @notice Deliberate revert carrying swap deltas from the callback.
  error QuoteSwapResult(int256 amount0Delta, int256 amount1Delta);
  /// @notice Wrapped downstream revert from a quote path.
  error WrappedError(address target, bytes4 selector, bytes reason);
  /// @notice pool.swap completed without callback revert.
  error QuoteDidNotRevert();
  /// @notice simulateSwapAndRevert completed without SimulateSwap revert.
  error HypotheticalQuoteDidNotRevert();
  /// @notice Provided unsigned amount does not fit in int128.
  error AmountTooLarge(uint128 amount);
  /// @notice Deltas do not match expected exact-in/out shape.
  error InvalidSwapDeltas();
  /// @notice Price-limit sentinel invalid for swap direction.
  error InvalidPriceLimitForDirection(bool zeroForOne, uint128 priceLimitX64);

  // ============ External: live quotes ============

  /// @notice Quote exact-input swap using live pool prices.
  function quoteLiveExactIn(address pool, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteLiveExactIn(pool, address(this), zeroForOne, amountIn, priceLimitX64, hex"");
  }

  /// @notice Quote exact-input swap with explicit recipient and extension context.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactIn(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteLiveSwap(pool, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, extensionData);
    return _decodeSwapAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  /// @notice Quote exact-output swap using live pool prices.
  function quoteLiveExactOut(address pool, bool zeroForOne, uint128 amountOutDesired, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteLiveExactOut(pool, address(this), zeroForOne, amountOutDesired, priceLimitX64, hex"");
  }

  /// @notice Quote exact-output swap with explicit recipient and extension context.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactOut(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteLiveSwap(pool, recipient, zeroForOne, _toSignedExactOutput(amountOutDesired), priceLimitX64, extensionData);
    return _decodeSwapAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  // ============ External: hypothetical quotes ============

  /// @notice Quote swap at caller-supplied bid/ask prices via simulateSwapAndRevert.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  function quoteHypotheticalSwap(
    address pool,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) public virtual returns (int128 amount0Delta, int128 amount1Delta) {
    return _quoteHypotheticalSwap(
      pool, msg.sender, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, hex""
    );
  }

  /// @notice Quote swap at caller-supplied bid/ask with explicit extension context.
  function quoteHypotheticalSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata extensionData
  ) public virtual returns (int128 amount0Delta, int128 amount1Delta) {
    return _quoteHypotheticalSwap(
      pool, recipient, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, extensionData
    );
  }

  // ============ External: callback ============

  /// @inheritdoc IMetricOmmSwapCallback
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    revert QuoteSwapResult(amount0Delta, amount1Delta);
  }

  // ============ Internal: live quote orchestration ============

  function _quoteLiveSwap(
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
      return _decodeLiveQuoteResult(reason, pool);
    }
  }

  function _decodeLiveQuoteResult(bytes memory reason, address pool)
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

  // ============ Internal: hypothetical quote orchestration ============

  function _quoteHypotheticalSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPool(pool)
      .simulateSwapAndRevert(
        recipient, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, extensionData
      ) {
      revert HypotheticalQuoteDidNotRevert();
    } catch (bytes memory reason) {
      return _decodeHypotheticalQuoteResult(reason, pool);
    }
  }

  function _decodeHypotheticalQuoteResult(bytes memory reason, address pool)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) == IMetricOmmPoolActions.SimulateSwap.selector) {
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
    revert WrappedError(pool, IMetricOmmPoolActions.simulateSwapAndRevert.selector, reason);
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
