// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title IMetricOmmSwapQuoter
/// @notice Off-chain swap quotes: live oracle prices via pool.swap, or hypothetical prices via simulateSwapAndRevert.
/// @dev For off-chain queries only (eth_call). Live quotes revert in the swap callback; hypothetical quotes read SimulateSwap revert data.
///      Multihop exact-input walks `pools` forward; prior hop output becomes next hop input. Multihop exact-output walks
///      `pools` backward; prior hop input becomes next hop output. Multihop paths use open per-hop price limits.
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
  /// @notice Route arrays are inconsistent, pools are not token-connected, or too short for a multihop path.
  error InvalidPath();
  /// @notice Exact-input hop consumed less input than requested (partial fill).
  error InvalidInputAmountAtHop(uint8 hop, uint256 amountIn, uint256 expectedAmountIn);
  /// @notice Exact-output hop output does not match the requested hop amount.
  error InvalidOutputAmountAtHop(uint8 hop, uint256 amountOut, uint256 expectedAmountOut);

  // ============ Types ============

  /// @notice Multihop live or hypothetical exact-input quote parameters.
  /// @param pools Pool between each hop; length must be at least one.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountIn Exact input amount for the first hop.
  struct QuoteExactInputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountIn;
  }

  /// @notice Multihop live or hypothetical exact-output quote parameters.
  /// @param pools Pool between each hop; length must be at least one.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountOut Exact output amount for the final hop.
  struct QuoteExactOutputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountOut;
  }

  /// @notice Multihop hypothetical exact-input quote parameters.
  /// @param bidPricesX64 Hypothetical bid price per pool; length must match `pools`.
  /// @param askPricesX64 Hypothetical ask price per pool; length must match `pools`.
  struct QuoteHypotheticalExactInputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountIn;
    uint128[] bidPricesX64;
    uint128[] askPricesX64;
  }

  /// @notice Multihop hypothetical exact-output quote parameters.
  /// @param bidPricesX64 Hypothetical bid price per pool; length must match `pools`.
  /// @param askPricesX64 Hypothetical ask price per pool; length must match `pools`.
  struct QuoteHypotheticalExactOutputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountOut;
    uint128[] bidPricesX64;
    uint128[] askPricesX64;
  }

  // ============ Live quotes: single hop ============

  /// @notice Quote single-hop exact-input swap using live pool prices.
  function quoteLiveExactInSingle(address pool, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
    external
    returns (uint256, uint256);

  /// @notice Quote single-hop exact-input swap with explicit recipient and extension context.
  function quoteLiveExactInSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  /// @notice Quote single-hop exact-output swap using live pool prices.
  function quoteLiveExactOutSingle(address pool, bool zeroForOne, uint128 amountOutDesired, uint128 priceLimitX64)
    external
    returns (uint256, uint256);

  /// @notice Quote single-hop exact-output swap with explicit recipient and extension context.
  function quoteLiveExactOutSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  // ============ Live quotes: multihop ============

  /// @notice Quote multihop exact-input swap using live pool prices.
  function quoteLiveExactIn(QuoteExactInputParams calldata params) external returns (uint256, uint256);

  /// @notice Quote multihop exact-output swap using live pool prices.
  function quoteLiveExactOut(QuoteExactOutputParams calldata params) external returns (uint256, uint256);

  // ============ Hypothetical quotes: single hop ============

  /// @notice Quote single-hop exact-input swap at caller-supplied bid/ask prices.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  function quoteHypotheticalExactInputSingle(
    address pool,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (uint256, uint256);

  /// @notice Quote single-hop exact-input swap at caller-supplied bid/ask with explicit extension context.
  function quoteHypotheticalExactInputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  /// @notice Quote single-hop exact-output swap at caller-supplied bid/ask prices.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  function quoteHypotheticalExactOutputSingle(
    address pool,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (uint256, uint256);

  /// @notice Quote single-hop exact-output swap at caller-supplied bid/ask with explicit extension context.
  function quoteHypotheticalExactOutputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) external returns (uint256, uint256);

  // ============ Hypothetical quotes: multihop ============

  /// @notice Quote multihop exact-input swap at caller-supplied bid/ask prices per pool.
  function quoteHypotheticalExactInput(QuoteHypotheticalExactInputParams calldata params)
    external
    returns (uint256, uint256);

  /// @notice Quote multihop exact-output swap at caller-supplied bid/ask prices per pool.
  function quoteHypotheticalExactOutput(QuoteHypotheticalExactOutputParams calldata params)
    external
    returns (uint256, uint256);
}
