// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {FeeMath} from "@metric-core/libraries/FeeMath.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {SwapMath} from "@metric-core/libraries/SwapMath.sol";
import {MetricOmmSwapPath} from "./MetricOmmSwapPath.sol";
import {MetricOmmSwapInputs} from "./MetricOmmSwapInputs.sol";
import {MetricOmmSwapQuoteDecode} from "./MetricOmmSwapQuoteDecode.sol";

/// @title LiquidityLadder
/// @notice Builds a pool's bid/ask depth ladder for `MetricOmmPoolDataProvider`.
/// @dev Depth ladder rows are sized from raw bin balances (the amount to fully cross each bin, from `slot0` and
///      per-bin state) and priced two ways: `lowerEffPriceX64`/`upperEffPriceX64` mirror the pool's own
///      per-bin execution-price formula (`MetricOmmPool._swapAcrossBins`: fee-adjust each bound, then interpolate
///      only for the in-bin current position), while `cumulativeOut`/`cumulativeIn` come from actually running the
///      cumulative amount through `simulateSwapAndRevert` - never re-derived swap math for the traded amounts.
///      Simulations use the data provider as both sender and recipient, with empty extension data; depth is
///      therefore evaluated in the provider's extension context, not a particular trader's or router's.
///      If a bin's full-crossing amount reverts for a reason other than the expected `SimulateSwap` payload (e.g. an
///      extension gate), the ladder binary-searches (bisecting from the bin's midpoint, up to `MAX_BINARY_SEARCH_ITERATIONS`
///      probes) the maximal amount that still succeeds within that bin, then stops - since any larger amount is
///      assumed to keep failing the same way.
library LiquidityLadder {
  using SafeCast for uint256;
  using SafeCast for int256;

  // ============ Errors ============

  /// @notice Oracle quote is invalid (`bid == 0`, `bid > ask`, or reference outside `[bid, ask]`).
  error InvalidOraclePrice();
  /// @notice Combined notional fee is greater than or equal to 100%.
  error InvalidNotionalFee();
  /// @notice Distance-based price conversion received a negative distance lower than -1e6.
  error InvalidDistance();
  error MaxBinsPerSideZero();
  /// @notice `simulateSwapAndRevert` completed without a `SimulateSwap` revert (violates its own contract).
  error SimulateSwapDidNotRevert();

  // ============ Types ============

  /// @notice One depth step on the ask (buy token0) or bid (sell token0) side.
  /// @param lowerEffPriceX64 Fee-adjusted execution price at the bin's lower bound.
  /// @param upperEffPriceX64 Fee-adjusted execution price at the bin's upper bound.
  /// @param amountAvailableInBin Raw amount tradeable in this bin per pool state, ignoring extensions (partial for the current bin).
  /// @param amountTradeableInBin Amount actually reachable in this bin once extension gates are accounted for; `< amountAvailableInBin` only on the row where the ladder stops.
  /// @param cumulativeOut Cumulative amount received by the trader through this bin (token0 for asks, token1 for bids).
  /// @param cumulativeIn Cumulative amount paid by the trader through this bin (token1 for asks, token0 for bids).
  struct DepthLevel {
    int16 binIdx;
    uint256 lowerEffPriceX64;
    uint256 upperEffPriceX64;
    uint256 amountAvailableInBin;
    uint256 amountTradeableInBin;
    uint256 cumulativeOut;
    uint256 cumulativeIn;
  }

  /// @notice Full depth snapshot for a pool.
  /// @param effectiveCurrentBidX64 Fee-adjusted sell price at the pool's exact current position.
  /// @param effectiveCurrentAskX64 Fee-adjusted buy price at the pool's exact current position.
  struct LiquidityDepth {
    uint128 oracleBidX64;
    uint128 oracleAskX64;
    uint128 oracleReferenceX64;
    uint128 effectiveCurrentBidX64;
    uint128 effectiveCurrentAskX64;
    DepthLevel[] asks;
    DepthLevel[] bids;
  }

  /// @dev Running ladder state, passed by reference so the build loops carry one pointer instead of three
  ///      separate stack slots (keeps the via-IR build's stack shallow).
  struct LadderAccumulator {
    uint256 cumOut;
    uint256 cumIn;
    uint256 filled;
  }

  /// @dev Bundles the per-side simulate-call parameters so ladder building and binary search pass one
  ///      memory pointer instead of four stack slots (keeps the via-IR build's stack shallow).
  struct SwapPriceContext {
    bool zeroForOne;
    uint128 priceLimitX64;
    uint128 bidPriceX64;
    uint128 askPriceX64;
    uint128 referencePriceX64;
  }

  /// @dev Packed read context to keep the build loops' stack shallow for via-IR builds.
  struct DepthEnv {
    PoolImmutables imm;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 baseBuyFeeX64;
    uint256 baseSellFeeX64;
    uint256 notionalFeeE8;
    int16 curBinIdx;
    uint104 curPosInBin;
    int24 curBinDistFromProvidedPriceE6;
  }

  // ============ Constants ============

  uint256 internal constant ONE_E6 = 1e6;
  uint256 internal constant ONE_E8 = 1e8;

  /// @dev Q64.64 fixed-point scale for marginal and execution prices (token1 per token0).
  uint256 internal constant Q64 = 1 << 64;

  uint256 internal constant MAX_POS_U104 = type(uint104).max;

  /// @dev Cap on bisection probes per failing bin: start at the midpoint of the bin's range, halve on each
  ///      probe. If none of them succeed, the bin is treated as having nothing tradable.
  uint256 internal constant MAX_BINARY_SEARCH_ITERATIONS = 20;

  // ============ Entry point ============

  function build(
    address pool,
    address factory,
    uint8 maxBinsPerSide,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) internal returns (LiquidityDepth memory depth) {
    if (maxBinsPerSide == 0) revert MaxBinsPerSideZero();
    if (
      bidPriceX64 == 0 || bidPriceX64 > askPriceX64 || referencePriceX64 < bidPriceX64
        || referencePriceX64 > askPriceX64
    ) {
      revert InvalidOraclePrice();
    }

    DepthEnv memory env = _loadDepthEnv(pool, factory, bidPriceX64, askPriceX64, referencePriceX64);

    depth.oracleBidX64 = bidPriceX64;
    depth.oracleAskX64 = askPriceX64;
    depth.oracleReferenceX64 = referencePriceX64;

    int16 highCap = _highBinCap(env.imm.highestBin, env.curBinIdx, maxBinsPerSide);
    depth.asks = _buildAskLadder(pool, env, bidPriceX64, askPriceX64, referencePriceX64, highCap);

    int16 lowCap = _lowBinCap(env.imm.lowestBin, env.curBinIdx, maxBinsPerSide);
    depth.bids = _buildBidLadder(pool, env, bidPriceX64, askPriceX64, referencePriceX64, lowCap);

    if (depth.asks.length > 0) {
      depth.effectiveCurrentAskX64 = SwapMath.calculatePriceAtBinPosition(
          depth.asks[0].lowerEffPriceX64, depth.asks[0].upperEffPriceX64, uint256(env.curPosInBin), Math.Rounding.Ceil
        ).toUint128();
    }
    if (depth.bids.length > 0) {
      depth.effectiveCurrentBidX64 = SwapMath.calculatePriceAtBinPosition(
          depth.bids[0].lowerEffPriceX64, depth.bids[0].upperEffPriceX64, uint256(env.curPosInBin), Math.Rounding.Ceil
        ).toUint128();
    }
  }

  // ============ Internal: depth context ============

  function _loadDepthEnv(
    address pool,
    address factory,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) internal view returns (DepthEnv memory env) {
    env.imm = IMetricOmmPool(pool).getImmutables();
    env.token0ScaleMultiplier = env.imm.token0ScaleMultiplier;
    env.token1ScaleMultiplier = env.imm.token1ScaleMultiplier;
    (,, uint24 protocolNotionalFeeE8, uint24 adminNotionalFeeE8) = IMetricOmmPoolFactory(factory).poolFeeConfig(pool);
    env.notionalFeeE8 = uint256(protocolNotionalFeeE8) + uint256(adminNotionalFeeE8);
    if (env.notionalFeeE8 >= ONE_E8) revert InvalidNotionalFee();

    (env.baseBuyFeeX64, env.baseSellFeeX64) = SwapMath.buySellBaseFeesX64FromBidAskAndReference(
      uint256(bidPriceX64), uint256(askPriceX64), uint256(referencePriceX64)
    );
    (, env.curBinIdx, env.curPosInBin, env.curBinDistFromProvidedPriceE6,,,) = PoolStateLibrary._slot0(pool);
  }

  function _highBinCap(int256 highestBin, int16 curBinIdx, uint8 maxBinsPerSide) internal pure returns (int16 highCap) {
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 hi = int256(curBinIdx) + int256(uint256(maxBinsPerSide));
    if (hi > highestBin) hi = highestBin;
    // forge-lint: disable-next-line(unsafe-typecast)
    highCap = int16(hi);
  }

  function _lowBinCap(int256 lowestBin, int16 curBinIdx, uint8 maxBinsPerSide) internal pure returns (int16 lowCap) {
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 lo = int256(curBinIdx) - int256(uint256(maxBinsPerSide));
    if (lo < lowestBin) lo = lowestBin;
    // forge-lint: disable-next-line(unsafe-typecast)
    lowCap = int16(lo);
  }

  // ============ Internal: reference-anchored bin bounds ============

  function _priceFromReferenceAndDistE6(uint256 referencePriceX64, int256 distE6, Math.Rounding rounding)
    internal
    pure
    returns (uint256)
  {
    if (distE6 >= 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 distAbs = uint256(distE6);
      return Math.mulDiv(referencePriceX64, ONE_E6 + distAbs, ONE_E6, rounding);
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 distNegAbs = uint256(-distE6);
    if (distNegAbs > ONE_E6) revert InvalidDistance();
    return Math.mulDiv(referencePriceX64, ONE_E6 - distNegAbs, ONE_E6, rounding);
  }

  function _toExternal(uint256 amountScaled, uint256 scaleMultiplier) internal pure returns (uint256) {
    if (scaleMultiplier == 0) {
      return amountScaled;
    }
    return amountScaled / scaleMultiplier;
  }

  /// @dev Fee-adjusted bounds and raw tradeable amount for one ask-side bin. Splitting this out of
  ///      `_buildAskLadder` keeps that loop's stack shallow enough for the via-IR build.
  function _askBinBounds(
    address pool,
    DepthEnv memory env,
    int16 binIdx,
    uint256 referencePriceX64,
    uint256 notionalFeeX64,
    int256 lowerDistE6
  )
    internal
    view
    returns (uint256 lowerEffPriceX64, uint256 upperEffPriceX64, uint256 amountAvailableInBin, uint256 lengthE6)
  {
    uint16 addFeeBuyE6;
    uint104 t0;
    (t0,, lengthE6, addFeeBuyE6,) = PoolStateLibrary._binState(pool, binIdx);

    uint256 lowerReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, lowerDistE6, Math.Rounding.Floor);
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 upperDistE6 = lowerDistE6 + int256(uint256(lengthE6));
    uint256 upperReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, upperDistE6, Math.Rounding.Floor);
    uint256 buyFeeX64 = FeeMath.binTotalFeeX64(env.baseBuyFeeX64, addFeeBuyE6, notionalFeeX64);
    lowerEffPriceX64 = FeeMath.effectivePriceX64(lowerReferencePriceX64, buyFeeX64, false);
    upperEffPriceX64 = FeeMath.effectivePriceX64(upperReferencePriceX64, buyFeeX64, false);

    uint256 amountScaled = binIdx == env.curBinIdx
      ? Math.mulDiv(uint256(t0), MAX_POS_U104 - uint256(env.curPosInBin), MAX_POS_U104, Math.Rounding.Floor)
      : uint256(t0);
    amountAvailableInBin = _toExternal(amountScaled, env.token0ScaleMultiplier);
  }

  /// @dev Fee-adjusted bounds and raw tradeable amount for one bid-side bin. `lowerDistE6` must already be this
  ///      bin's own lower-bound distance (the caller walks it down bin-by-bin); see `_buildBidLadder`.
  function _bidBinBounds(
    address pool,
    DepthEnv memory env,
    int16 binIdx,
    uint256 referencePriceX64,
    uint256 notionalFeeX64,
    int256 lowerDistE6
  ) internal view returns (uint256 lowerEffPriceX64, uint256 upperEffPriceX64, uint256 amountAvailableInBin) {
    (, uint104 t1, uint16 lengthE6,, uint16 addFeeSellE6) = PoolStateLibrary._binState(pool, binIdx);

    uint256 lowerReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, lowerDistE6, Math.Rounding.Floor);
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 upperDistE6 = lowerDistE6 + int256(uint256(lengthE6));
    uint256 upperReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, upperDistE6, Math.Rounding.Floor);
    uint256 sellFeeX64 = FeeMath.binTotalFeeX64(env.baseSellFeeX64, addFeeSellE6, notionalFeeX64);
    lowerEffPriceX64 = FeeMath.effectivePriceX64(lowerReferencePriceX64, sellFeeX64, true);
    upperEffPriceX64 = FeeMath.effectivePriceX64(upperReferencePriceX64, sellFeeX64, true);

    uint256 amountScaled = binIdx == env.curBinIdx
      ? Math.mulDiv(uint256(t1), uint256(env.curPosInBin), MAX_POS_U104, Math.Rounding.Floor)
      : uint256(t1);
    amountAvailableInBin = _toExternal(amountScaled, env.token1ScaleMultiplier);
  }

  /// @dev A bin's own length, in E6. The caller derives a lower bin's lower-bound distance from the bin above's
  ///      (contiguous) lower-bound distance minus the LOWER bin's own length - see `_buildBidLadder`.
  function _binLengthE6(address pool, int16 binIdx) internal view returns (uint16 lengthE6) {
    (,, lengthE6,,) = PoolStateLibrary._binState(pool, binIdx);
  }

  // ============ Internal: depth ladder walks ============
  // A bin with zero raw balance still gets a row (flat cumulatives) and the walk continues past it.

  function _buildAskLadder(
    address pool,
    DepthEnv memory env,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int16 highCap
  ) internal returns (DepthLevel[] memory asks) {
    // casting to 'uint256' is safe because the ternary guard 'env.curBinIdx <= highCap' ensures the
    // int16 difference plus 1 is always >= 1, so no sign reinterpretation occurs
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 maxRows = env.curBinIdx <= highCap ? uint256(int256(highCap) - int256(env.curBinIdx) + 1) : 0;
    asks = new DepthLevel[](maxRows);
    if (maxRows == 0) return asks;

    SwapPriceContext memory ctx = SwapPriceContext({
      zeroForOne: false,
      priceLimitX64: MetricOmmSwapPath.openLimit(false),
      bidPriceX64: bidPriceX64,
      askPriceX64: askPriceX64,
      referencePriceX64: referencePriceX64
    });

    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(env.notionalFeeE8));
    int256 cumDistE6 = int256(env.curBinDistFromProvidedPriceE6);
    LadderAccumulator memory acc;

    for (int256 b = int256(env.curBinIdx); b <= int256(highCap); b++) {
      // forge-lint: disable-next-line(unsafe-typecast)
      int16 binIdx = int16(b);
      bool shouldStop;
      (cumDistE6, shouldStop) = _processAskBin(pool, env, ctx, notionalFeeX64, binIdx, cumDistE6, asks, acc);
      if (shouldStop) break;
    }

    _truncate(asks, acc.filled);
  }

  /// @dev One ask-side bin: bounds + sizing + simulate + row recording. Split out of `_buildAskLadder`'s loop to
  ///      keep that loop's stack shallow for the via-IR build.
  function _processAskBin(
    address pool,
    DepthEnv memory env,
    SwapPriceContext memory ctx,
    uint256 notionalFeeX64,
    int16 binIdx,
    int256 cumDistE6,
    DepthLevel[] memory asks,
    LadderAccumulator memory acc
  ) internal returns (int256 nextCumDistE6, bool shouldStop) {
    (uint256 lowerEffPriceX64, uint256 upperEffPriceX64, uint256 amountAvailableInBin, uint256 lengthE6) =
      _askBinBounds(pool, env, binIdx, uint256(ctx.referencePriceX64), notionalFeeX64, cumDistE6);
    // forge-lint: disable-next-line(unsafe-typecast)
    nextCumDistE6 = cumDistE6 + int256(lengthE6);

    uint256 outAmt;
    uint256 inAmt;
    bool madeProgress;
    if (amountAvailableInBin > 0) {
      (outAmt, inAmt, madeProgress) = _maxSucceedingAmount(pool, ctx, acc.cumOut, amountAvailableInBin);
    }
    bool reachedFullBin = _recordLadderRow(
      asks, acc, binIdx, lowerEffPriceX64, upperEffPriceX64, amountAvailableInBin, outAmt, inAmt, madeProgress
    );
    shouldStop = amountAvailableInBin > 0 && !reachedFullBin;
  }

  function _buildBidLadder(
    address pool,
    DepthEnv memory env,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int16 lowCap
  ) internal returns (DepthLevel[] memory bids) {
    // casting to 'uint256' is safe because the ternary guard 'env.curBinIdx >= lowCap' ensures the
    // int16 difference plus 1 is always >= 1, so no sign reinterpretation occurs
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 maxRows = env.curBinIdx >= lowCap ? uint256(int256(env.curBinIdx) - int256(lowCap) + 1) : 0;
    bids = new DepthLevel[](maxRows);
    if (maxRows == 0) return bids;

    SwapPriceContext memory ctx = SwapPriceContext({
      zeroForOne: true,
      priceLimitX64: MetricOmmSwapPath.openLimit(true),
      bidPriceX64: bidPriceX64,
      askPriceX64: askPriceX64,
      referencePriceX64: referencePriceX64
    });

    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(env.notionalFeeE8));
    int256 walkDistE6 = int256(env.curBinDistFromProvidedPriceE6);
    LadderAccumulator memory acc;

    for (int256 b = int256(env.curBinIdx); b >= int256(lowCap); b--) {
      // forge-lint: disable-next-line(unsafe-typecast)
      int16 binIdx = int16(b);
      if (binIdx != env.curBinIdx) {
        // forge-lint: disable-next-line(unsafe-typecast)
        walkDistE6 -= int256(uint256(_binLengthE6(pool, binIdx)));
      }

      bool shouldStop;
      (walkDistE6, shouldStop) = _processBidBin(pool, env, ctx, notionalFeeX64, binIdx, walkDistE6, bids, acc);
      if (shouldStop) break;
    }

    _truncate(bids, acc.filled);
  }

  /// @dev One bid-side bin: bounds + sizing + simulate + row recording. `walkDistE6` in must already be `binIdx`'s
  ///      own lower-bound distance (the caller decrements it bin-by-bin before calling). Split out of
  ///      `_buildBidLadder`'s loop to keep that loop's stack shallow for the via-IR build.
  function _processBidBin(
    address pool,
    DepthEnv memory env,
    SwapPriceContext memory ctx,
    uint256 notionalFeeX64,
    int16 binIdx,
    int256 walkDistE6,
    DepthLevel[] memory bids,
    LadderAccumulator memory acc
  ) internal returns (int256 nextWalkDistE6, bool shouldStop) {
    nextWalkDistE6 = walkDistE6;
    (uint256 lowerEffPriceX64, uint256 upperEffPriceX64, uint256 amountAvailableInBin) =
      _bidBinBounds(pool, env, binIdx, uint256(ctx.referencePriceX64), notionalFeeX64, walkDistE6);

    uint256 outAmt;
    uint256 inAmt;
    bool madeProgress;
    if (amountAvailableInBin > 0) {
      (outAmt, inAmt, madeProgress) = _maxSucceedingAmount(pool, ctx, acc.cumOut, amountAvailableInBin);
    }
    bool reachedFullBin = _recordLadderRow(
      bids, acc, binIdx, lowerEffPriceX64, upperEffPriceX64, amountAvailableInBin, outAmt, inAmt, madeProgress
    );
    shouldStop = amountAvailableInBin > 0 && !reachedFullBin;
  }

  /// @dev Appends one row using `acc.cumOut`/`acc.cumIn` as the prior cumulative and advances `acc` in place.
  ///      Returns whether this bin's full `amountAvailableInBin` was reached (false for a zero-amount bin too,
  ///      but the caller only treats that as a stop when `amountAvailableInBin > 0`).
  function _recordLadderRow(
    DepthLevel[] memory levels,
    LadderAccumulator memory acc,
    int16 binIdx,
    uint256 lowerEffPriceX64,
    uint256 upperEffPriceX64,
    uint256 amountAvailableInBin,
    uint256 outAmt,
    uint256 inAmt,
    bool madeProgress
  ) internal pure returns (bool reachedFullBin) {
    uint256 priorCumOut = acc.cumOut;
    reachedFullBin = madeProgress && (outAmt - priorCumOut) == amountAvailableInBin;

    levels[acc.filled] = DepthLevel({
      binIdx: binIdx,
      lowerEffPriceX64: lowerEffPriceX64,
      upperEffPriceX64: upperEffPriceX64,
      amountAvailableInBin: amountAvailableInBin,
      amountTradeableInBin: madeProgress ? outAmt - priorCumOut : 0,
      cumulativeOut: madeProgress ? outAmt : priorCumOut,
      cumulativeIn: madeProgress ? inAmt : acc.cumIn
    });
    acc.filled++;
    if (madeProgress) {
      acc.cumOut = outAmt;
      acc.cumIn = inAmt;
    }
  }

  // ============ Internal: simulate-backed sizing with binary-search fallback ============

  /// @dev Tries the full-bin candidate first. If it fails to decode as `SimulateSwap` (e.g. an extension gate),
  ///      binary-searches `[lastGoodCumAmt, lastGoodCumAmt + binExternalAmount]` starting at its midpoint, for up
  ///      to `MAX_BINARY_SEARCH_ITERATIONS` probes, keeping the largest amount found to still succeed. Returns
  ///      `madeProgress = false` if none of the probes ever succeed (nothing tradable in this bin).
  function _maxSucceedingAmount(
    address pool,
    SwapPriceContext memory ctx,
    uint256 lastGoodCumAmt,
    uint256 binExternalAmount
  ) internal returns (uint256 outAmt, uint256 inAmt, bool madeProgress) {
    uint256 candidate = lastGoodCumAmt + binExternalAmount;
    (bool candidateOk, uint256 cOut, uint256 cIn) = _trySimulateExactOutput(pool, ctx, candidate);
    if (candidateOk) return (cOut, cIn, true);

    uint256 lo = lastGoodCumAmt;
    uint256 hi = candidate;

    for (uint256 i; i < MAX_BINARY_SEARCH_ITERATIONS; ++i) {
      if (hi - lo <= 1) break;
      uint256 mid = lo + (hi - lo) / 2;
      (bool midOk, uint256 mOut, uint256 mIn) = _trySimulateExactOutput(pool, ctx, mid);
      if (midOk) {
        lo = mid;
        outAmt = mOut;
        inAmt = mIn;
        madeProgress = true;
      } else {
        hi = mid;
      }
    }
  }

  /// @dev Decodes the `SimulateSwap` revert into direction-agnostic `(outAmt, inAmt)`: the amount the trader
  ///      receives and pays, regardless of which token0/token1 leg that maps to for `ctx.zeroForOne`.
  function _trySimulateExactOutput(address pool, SwapPriceContext memory ctx, uint256 amountOutExternal)
    internal
    returns (bool ok, uint256 outAmt, uint256 inAmt)
  {
    int128 amountSpecified = MetricOmmSwapInputs.asAmountSpecifiedOut(MetricOmmSwapInputs.toUint128(amountOutExternal));
    try IMetricOmmPoolActions(pool)
      .simulateSwapAndRevert(
        address(this),
        address(this),
        ctx.zeroForOne,
        amountSpecified,
        ctx.priceLimitX64,
        ctx.bidPriceX64,
        ctx.askPriceX64,
        ctx.referencePriceX64,
        hex""
      ) returns (
      int128, int128
    ) {
      revert SimulateSwapDidNotRevert();
    } catch (bytes memory reason) {
      (int128 amount0Delta, int128 amount1Delta, bool matched) =
        MetricOmmSwapQuoteDecode.decodeSwapDeltas(reason, IMetricOmmPoolActions.SimulateSwap.selector);
      if (!matched) return (false, 0, 0);
      ok = true;
      if (ctx.zeroForOne) {
        outAmt = (-int256(amount1Delta)).toUint256();
        inAmt = int256(amount0Delta).toUint256();
      } else {
        outAmt = (-int256(amount0Delta)).toUint256();
        inAmt = int256(amount1Delta).toUint256();
      }
    }
  }

  function _truncate(DepthLevel[] memory levels, uint256 length) internal pure {
    assembly ("memory-safe") {
      mstore(levels, length)
    }
  }
}
