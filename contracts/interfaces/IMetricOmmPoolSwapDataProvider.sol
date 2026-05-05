// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {IMetricOmmPoolQuoter} from "./IMetricOmmPoolQuoter.sol";

/// @title IMetricOmmPoolSwapDataProvider
/// @notice Read-only pool swap data: fee-adjusted bid/ask, per-bin depth ladders, and revert-based swap quotes.
interface IMetricOmmPoolSwapDataProvider is IMetricOmmPoolQuoter {
  // ============ Errors ============

  /// @notice Constructor received zero factory address.
  error InvalidFactory();
  /// @notice Pool has neither mutable nor immutable price provider configured.
  error InvalidPriceProvider();
  /// @notice Oracle quote is invalid (`bid == 0` or `bid > ask`).
  error InvalidOraclePrice();
  /// @notice Combined notional fee is greater than or equal to 100%.
  error InvalidNotionalFee();
  /// @notice Distance-based price conversion received a negative distance lower than -1e6.
  error InvalidDistance();
  /// @notice Requested depth window exceeds the configured maximum.
  error MaxBinsPerSideTooLarge();
  /// @notice Bid depth ladder implied zero fee-adjusted execution price for a bin (division impossible).
  error BidDepthBinAvgExecPriceZero();

  // ============ Types ============

  /// @notice One depth step on the ask (buy token0) or bid (sell token0) side.
  /// @dev On the bid side, `amountInBin` / `amountCumulative` are token1 output; `binAvgExecPriceX64` and
  ///      `cumulativeAvgExecPriceX64` are token1 per token0 (Q64.64). The cumulative average is VWAP in token1 per token0
  ///      (total token1 out over cumulative implied token0 sold), not a proceeds-weighted average of per-bin prices.
  struct DepthLevel {
    int8 binIdx;
    uint256 amountInBin;
    uint256 amountCumulative;
    uint256 binAvgExecPriceX64;
    uint256 cumulativeAvgExecPriceX64;
  }

  /// @notice Full depth snapshot for a pool.
  struct LiquidityDepth {
    uint128 oracleBidX64;
    uint128 oracleAskX64;
    uint128 referenceBestBidX64;
    uint128 referenceBestAskX64;
    DepthLevel[] asks;
    DepthLevel[] bids;
  }

  // ============ Views ============

  /// @notice Returns fee-adjusted best executable bid/ask prices in Q64.64.
  function getBestBidAndAsk(address pool) external view returns (uint128 bestBidX64, uint128 bestAskX64);

  /// @notice Computes read-only bid and ask depth ladders from the pool's current bin outward.
  function getLiquidityDepth(address pool, uint8 maxBinsPerSide) external view returns (LiquidityDepth memory depth);
}
