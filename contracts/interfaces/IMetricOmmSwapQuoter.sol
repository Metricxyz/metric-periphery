// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title IMetricOmmSwapQuoter
/// @notice Off-chain swap quotes: live oracle prices via pool.swap, or hypothetical prices via simulateSwapAndRevert.
/// @dev For off-chain queries only (eth_call). Live quotes revert in the swap callback; hypothetical quotes read SimulateSwap revert data.
interface IMetricOmmSwapQuoter is IMetricOmmSwapCallback {
  // ============ Errors ============

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

  // ============ Live quotes ============

  /// @notice Quote exact-input swap using live pool prices.
  /// @param pool MetricOmm pool address.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountIn Exact input amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactIn(address pool, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
    external
    returns (uint256, uint256);

  /// @notice Quote exact-input swap with explicit recipient and extension context.
  /// @param pool MetricOmm pool address.
  /// @param recipient Swap recipient passed to pool.swap.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountIn Exact input amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactIn(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  /// @notice Quote exact-output swap using live pool prices.
  /// @param pool MetricOmm pool address.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountOutDesired Exact output amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactOut(address pool, bool zeroForOne, uint128 amountOutDesired, uint128 priceLimitX64)
    external
    returns (uint256, uint256);

  /// @notice Quote exact-output swap with explicit recipient and extension context.
  /// @param pool MetricOmm pool address.
  /// @param recipient Swap recipient passed to pool.swap.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountOutDesired Exact output amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteLiveExactOut(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  // ============ Hypothetical quotes ============

  /// @notice Quote exact-input swap at caller-supplied bid/ask prices via simulateSwapAndRevert.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  /// @param pool MetricOmm pool address.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountIn Exact input amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param bidPriceX64 Hypothetical bid price in Q64.64.
  /// @param askPriceX64 Hypothetical ask price in Q64.64.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteHypotheticalExactInput(
    address pool,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (uint256, uint256);

  /// @notice Quote exact-input swap at caller-supplied bid/ask with explicit extension context.
  /// @param pool MetricOmm pool address.
  /// @param recipient Swap recipient passed to simulateSwapAndRevert.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountIn Exact input amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param bidPriceX64 Hypothetical bid price in Q64.64.
  /// @param askPriceX64 Hypothetical ask price in Q64.64.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteHypotheticalExactInput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  /// @notice Quote exact-output swap at caller-supplied bid/ask prices via simulateSwapAndRevert.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  /// @param pool MetricOmm pool address.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountOutDesired Exact output amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param bidPriceX64 Hypothetical bid price in Q64.64.
  /// @param askPriceX64 Hypothetical ask price in Q64.64.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteHypotheticalExactOutput(
    address pool,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (uint256, uint256);

  /// @notice Quote exact-output swap at caller-supplied bid/ask with explicit extension context.
  /// @param pool MetricOmm pool address.
  /// @param recipient Swap recipient passed to simulateSwapAndRevert.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountOutDesired Exact output amount.
  /// @param priceLimitX64 Q64.64 execution bound.
  /// @param bidPriceX64 Hypothetical bid price in Q64.64.
  /// @param askPriceX64 Hypothetical ask price in Q64.64.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  /// @return amountIn Input token amount for the swap.
  /// @return amountOut Output token amount for the swap.
  function quoteHypotheticalExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);
}
