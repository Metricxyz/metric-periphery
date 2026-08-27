// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {FeeMath} from "@metric-core/libraries/FeeMath.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {SwapMath} from "@metric-core/libraries/SwapMath.sol";
import {MetricOmmPoolStateView} from "../common/MetricOmmPoolStateView.sol";

/// @title MetricOmmPoolDataProvider
/// @notice Read-only swap data for MetricOMM pools: per-bin depth ladders and revert-based quotes.
/// @dev For off-chain queries only (e.g. `eth_call`, indexers, UIs). Do not call from other contracts inside a transaction; this lens is not gas-optimized for on-chain composition.
contract MetricOmmPoolDataProvider is MetricOmmPoolStateView {
  using SafeCast for uint256;

  // ============ Errors ============

  /// @notice Constructor received zero factory address.
  error InvalidFactory();
  /// @notice Pool has neither mutable nor immutable price provider configured.
  error InvalidPriceProvider();
  /// @notice Oracle quote is invalid (`bid == 0`, `bid > ask`, or reference outside `[bid, ask]`).
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
  struct DepthLevel {
    int16 binIdx;
    uint256 amountInBin;
    uint256 amountCumulative;
    uint256 binAvgExecPriceX64;
    uint256 cumulativeAvgExecPriceX64;
  }

  /// @notice Full depth snapshot for a pool.
  struct LiquidityDepth {
    uint128 oracleBidX64;
    uint128 oracleAskX64;
    uint128 oracleReferenceX64;
    uint128 referenceBestBidX64;
    uint128 referenceBestAskX64;
    DepthLevel[] asks;
    DepthLevel[] bids;
  }

  /// @dev Packed read context to keep `getLiquidityDepth` stack shallow for via-IR builds.
  struct DepthEnv {
    PoolImmutables imm;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 baseBuyFeeX64;
    uint256 baseSellFeeX64;
    uint256 notionalFeeE8;
    uint128 oracleBidX64;
    uint128 oracleAskX64;
    uint128 oracleReferenceX64;
    int16 curBinIdx;
    uint104 curPosInBin;
    int24 curBinDistFromProvidedPriceE6;
  }

  // ============ Constants ============

  uint256 internal constant ONE_E6 = 1e6;
  uint256 internal constant ONE_E8 = 1e8;

  /// @dev Q64.64 fixed-point scale for marginal and execution prices (token1 per token0).
  uint256 internal constant Q64 = 1 << 64;

  /// @dev Depth walk window cap (independent of pool grid size; grids may exceed int8 range).
  uint8 internal constant MAX_BINS_PER_SIDE_CAP = 255;

  uint256 internal constant MAX_POS_U104 = type(uint104).max;

  /// @dev Mutable walk state for `_fillAsks` to keep the outer loop stack shallow.
  struct AskFillCtx {
    uint256 cumAmt;
    uint256 cumWeighted;
    int256 cumDistE6;
    uint256 out;
  }

  // ============ Constructor ============

  constructor(address factory) MetricOmmPoolStateView(factory) {
    if (factory == address(0)) revert InvalidFactory();
  }

  // ============ External: swap data views ============

  /// @notice Returns current distance from provided/reference price in signed X64 percentage units.
  function distanceFromProvidedPriceX64(address pool) external view returns (int256 distanceX64) {
    (, int16 curBinIdx, uint104 curPosInBin, int24 curBinDistFromProvidedPriceE6,,,) = PoolStateLibrary._slot0(pool);
    (,, uint16 lengthE6,,) = PoolStateLibrary._binState(pool, curBinIdx);

    int256 baseDistE6 = int256(curBinDistFromProvidedPriceE6);
    int256 baseDistAbsE6 = baseDistE6 >= 0 ? baseDistE6 : -baseDistE6;
    // casting to `uint256` is safe because `baseDistAbsE6` is made non-negative above
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 baseDistAbsX64 = Math.mulDiv(uint256(baseDistAbsE6), Q64, ONE_E6, Math.Rounding.Floor);
    // casting to `int256` is safe because `baseDistAbsX64` is derived from bounded E6 distance and scales linearly
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 signedBaseDistX64 = baseDistE6 >= 0 ? int256(baseDistAbsX64) : -int256(baseDistAbsX64);

    uint256 inBinDistNumerator = uint256(lengthE6) * uint256(curPosInBin);
    uint256 inBinDistX64 = Math.mulDiv(inBinDistNumerator, Q64, ONE_E6 * MAX_POS_U104, Math.Rounding.Floor);

    // casting to `int256` is safe because `inBinDistX64` is non-negative and bounded by one-bin distance in X64
    // forge-lint: disable-next-line(unsafe-typecast)
    distanceX64 = signedBaseDistX64 + int256(inBinDistX64);
  }

  // ---- Per-bin depth ladders ----

  /// @notice Computes read-only bid and ask depth ladders from the pool's current bin outward.
  function getLiquidityDepth(address pool, uint8 maxBinsPerSide) external returns (LiquidityDepth memory depth) {
    if (maxBinsPerSide == 0 || maxBinsPerSide > MAX_BINS_PER_SIDE_CAP) revert MaxBinsPerSideTooLarge();

    DepthEnv memory env = _loadDepthEnv(pool);
    if (
      env.oracleBidX64 == 0 || env.oracleBidX64 > env.oracleAskX64 || env.oracleReferenceX64 < env.oracleBidX64
        || env.oracleReferenceX64 > env.oracleAskX64
    ) revert InvalidOraclePrice();

    depth.oracleBidX64 = env.oracleBidX64;
    depth.oracleAskX64 = env.oracleAskX64;
    depth.oracleReferenceX64 = env.oracleReferenceX64;

    (depth.referenceBestBidX64, depth.referenceBestAskX64) = _marginalBestBidAsk(
      pool,
      env.baseBuyFeeX64,
      env.baseSellFeeX64,
      env.notionalFeeE8,
      env.oracleReferenceX64,
      env.curBinIdx,
      env.curPosInBin,
      env.curBinDistFromProvidedPriceE6
    );

    uint256 referencePriceX64 = uint256(env.oracleReferenceX64);

    int16 highCap = _highBinCap(env.imm.highestBin, env.curBinIdx, maxBinsPerSide);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 askCount = env.curBinIdx <= highCap ? uint256(int256(highCap) - int256(env.curBinIdx) + 1) : 0;
    depth.asks = new DepthLevel[](askCount);
    _fillAsks(
      pool,
      env.token0ScaleMultiplier,
      referencePriceX64,
      env.baseBuyFeeX64,
      env.notionalFeeE8,
      env.curBinIdx,
      env.curPosInBin,
      env.curBinDistFromProvidedPriceE6,
      highCap,
      depth.asks
    );

    int16 lowCap = _lowBinCap(env.imm.lowestBin, env.curBinIdx, maxBinsPerSide);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 bidCount = env.curBinIdx >= lowCap ? uint256(int256(env.curBinIdx) - int256(lowCap) + 1) : 0;
    depth.bids = new DepthLevel[](bidCount);
    _fillBids(
      pool,
      env.token1ScaleMultiplier,
      referencePriceX64,
      env.baseSellFeeX64,
      env.notionalFeeE8,
      env.curBinIdx,
      env.curPosInBin,
      env.curBinDistFromProvidedPriceE6,
      lowCap,
      depth.bids
    );
  }

  // ============ Internal: factory and depth context ============

  function _resolvePriceProvider(address pool) internal view returns (address provider) {
    provider = PoolStateLibrary._slot3(pool);
    if (provider == address(0)) {
      provider = IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
    }
    if (provider == address(0)) revert InvalidPriceProvider();
  }

  function _loadDepthEnv(address pool) internal returns (DepthEnv memory env) {
    env.imm = IMetricOmmPool(pool).getImmutables();
    env.token0ScaleMultiplier = env.imm.token0ScaleMultiplier;
    env.token1ScaleMultiplier = env.imm.token1ScaleMultiplier;
    (,, uint24 protocolNotionalFeeE8, uint24 adminNotionalFeeE8) = IMetricOmmPoolFactory(FACTORY).poolFeeConfig(pool);
    env.notionalFeeE8 = uint256(protocolNotionalFeeE8) + uint256(adminNotionalFeeE8);
    if (env.notionalFeeE8 >= ONE_E8) revert InvalidNotionalFee();

    address provider = _resolvePriceProvider(pool);
    (env.oracleBidX64, env.oracleAskX64, env.oracleReferenceX64) = IPriceProvider(provider).getQuote();
    (env.baseBuyFeeX64, env.baseSellFeeX64) = SwapMath.buySellBaseFeesX64FromBidAskAndReference(
      uint256(env.oracleBidX64), uint256(env.oracleAskX64), uint256(env.oracleReferenceX64)
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

  // ============ Internal: reference-anchored ladder geometry ============

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

  // ============ Internal: reference best bid/ask ============

  function _marginalBestBidAsk(
    address pool,
    uint256 baseBuyFeeX64,
    uint256 baseSellFeeX64,
    uint256 notionalFeeE8,
    uint128 referenceFromOracleX64,
    int16 curBinIdx,
    uint104 curPosInBin,
    int24 curBinDistFromProvidedPriceE6
  ) internal view returns (uint128 bestBidX64, uint128 bestAskX64) {
    (,, uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6) = PoolStateLibrary._binState(pool, curBinIdx);
    uint256 marginalPriceX64;
    {
      uint256 referencePriceX64 = uint256(referenceFromOracleX64);
      uint256 lowerPriceX64 =
        _priceFromReferenceAndDistE6(referencePriceX64, int256(curBinDistFromProvidedPriceE6), Math.Rounding.Floor);
      uint256 upperPriceX64 = _priceFromReferenceAndDistE6(
        referencePriceX64,
        // forge-lint: disable-next-line(unsafe-typecast)
        int256(curBinDistFromProvidedPriceE6) + int256(uint256(lengthE6)),
        Math.Rounding.Floor
      );
      marginalPriceX64 =
        SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, uint256(curPosInBin), Math.Rounding.Floor);
    }

    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(notionalFeeE8));
    bestAskX64 = FeeMath.effectivePriceX64(
        marginalPriceX64, FeeMath.binTotalFeeX64(baseBuyFeeX64, addFeeBuyE6, notionalFeeX64), false
      ).toUint128();
    bestBidX64 = FeeMath.effectivePriceX64(
        marginalPriceX64, FeeMath.binTotalFeeX64(baseSellFeeX64, addFeeSellE6, notionalFeeX64), true
      ).toUint128();
  }

  // ============ Internal: fee-adjusted prices and depth accumulation ============

  function _feeAdjustedAskX64(uint256 marginalX64, uint256 buyFeeX64) internal pure returns (uint256) {
    return FeeMath.effectivePriceX64(marginalX64, buyFeeX64, false);
  }

  function _feeAdjustedBidX64(uint256 marginalX64, uint256 sellFeeX64) internal pure returns (uint256) {
    return FeeMath.effectivePriceX64(marginalX64, sellFeeX64, true);
  }

  function _accumulateAskLevel(
    uint256 buyFeeX64,
    uint256 amountExternal,
    uint256 mStartX64,
    uint256 mEndX64,
    uint256 cumAmt,
    uint256 cumWeighted
  ) internal pure returns (uint256 binAvgExecPriceX64, uint256 newCumAmt, uint256 newCumWeighted) {
    uint256 execStart = _feeAdjustedAskX64(mStartX64, buyFeeX64);
    uint256 execEnd = _feeAdjustedAskX64(mEndX64, buyFeeX64);
    binAvgExecPriceX64 = (execStart + execEnd) >> 1;

    newCumAmt = cumAmt + amountExternal;
    newCumWeighted = cumWeighted + binAvgExecPriceX64 * amountExternal;
  }

  /// @dev `amountExternal` is token1 output for this bin slice. Execution price is token1 per token0 (Q64.64), so VWAP
  ///      weights each bin by implied token0 sold: Δx ≈ Δy·Q64/P, not by Δy (which skewed `Σ(P·Δy)/Σ(Δy)` vs `ΣΔy/ΣΔx`).
  function _accumulateBidLevel(
    uint256 sellFeeX64,
    uint256 amountExternal,
    uint256 mStartX64,
    uint256 mEndX64,
    uint256 cumToken1Out,
    uint256 cumToken0Sold
  ) internal pure returns (uint256 binAvgExecPriceX64, uint256 newCumToken1Out, uint256 newCumToken0Sold) {
    uint256 execStart = _feeAdjustedBidX64(mStartX64, sellFeeX64);
    uint256 execEnd = _feeAdjustedBidX64(mEndX64, sellFeeX64);
    binAvgExecPriceX64 = (execStart + execEnd) >> 1;
    if (binAvgExecPriceX64 == 0) revert BidDepthBinAvgExecPriceZero();

    newCumToken1Out = cumToken1Out + amountExternal;
    uint256 token0Slice = Math.mulDiv(amountExternal, Q64, binAvgExecPriceX64, Math.Rounding.Floor);
    newCumToken0Sold = cumToken0Sold + token0Slice;
  }

  // ============ Internal: depth ladder walks ============

  function _fillAsks(
    address pool,
    uint256 token0ScaleMultiplier,
    uint256 referencePriceX64,
    uint256 baseBuyFeeX64,
    uint256 notionalFeeE8,
    int16 curBinIdx,
    uint104 curPosInBin,
    int24 curBinDistFromProvidedPriceE6,
    int16 highCap,
    DepthLevel[] memory asks
  ) internal view {
    AskFillCtx memory ctx;
    ctx.cumDistE6 = int256(curBinDistFromProvidedPriceE6);
    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(notionalFeeE8));
    for (int256 b = int256(curBinIdx); b <= int256(highCap); b++) {
      _fillAskRow(
        pool,
        token0ScaleMultiplier,
        referencePriceX64,
        baseBuyFeeX64,
        notionalFeeX64,
        curBinIdx,
        curPosInBin,
        asks,
        ctx,
        b
      );
      unchecked {
        ++ctx.out;
      }
    }
  }

  function _fillAskRow(
    address pool,
    uint256 token0ScaleMultiplier,
    uint256 referencePriceX64,
    uint256 baseBuyFeeX64,
    uint256 notionalFeeX64,
    int16 curBinIdx,
    uint104 curPosInBin,
    DepthLevel[] memory asks,
    AskFillCtx memory ctx,
    int256 b
  ) private view {
    // forge-lint: disable-next-line(unsafe-typecast)
    int16 binIdx = int16(b);
    (uint104 t0,, uint16 lengthE6, uint16 addFeeBuyE6,) = PoolStateLibrary._binState(pool, binIdx);
    uint256 buyFeeX64 = FeeMath.binTotalFeeX64(baseBuyFeeX64, addFeeBuyE6, notionalFeeX64);

    uint256 lowerX64 = _priceFromReferenceAndDistE6(referencePriceX64, ctx.cumDistE6, Math.Rounding.Floor);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 upperX64 =
      _priceFromReferenceAndDistE6(referencePriceX64, ctx.cumDistE6 + int256(uint256(lengthE6)), Math.Rounding.Floor);

    uint256 amountScaled;
    uint256 mStartX64;
    uint256 mEndX64;

    if (binIdx == curBinIdx) {
      amountScaled = Math.mulDiv(uint256(t0), MAX_POS_U104 - uint256(curPosInBin), MAX_POS_U104, Math.Rounding.Floor);
      mStartX64 = SwapMath.calculatePriceAtBinPosition(lowerX64, upperX64, uint256(curPosInBin), Math.Rounding.Floor);
      mEndX64 = upperX64;
    } else {
      amountScaled = uint256(t0);
      mStartX64 = lowerX64;
      mEndX64 = upperX64;
    }

    uint256 amountExternal = _toExternal(amountScaled, token0ScaleMultiplier);

    uint256 binAvg;
    (binAvg, ctx.cumAmt, ctx.cumWeighted) =
      _accumulateAskLevel(buyFeeX64, amountExternal, mStartX64, mEndX64, ctx.cumAmt, ctx.cumWeighted);

    uint256 cumVwapX64 = ctx.cumAmt == 0 ? 0 : ctx.cumWeighted / ctx.cumAmt;
    asks[ctx.out] = DepthLevel({
      binIdx: binIdx,
      amountInBin: amountExternal,
      amountCumulative: ctx.cumAmt,
      binAvgExecPriceX64: binAvg,
      cumulativeAvgExecPriceX64: cumVwapX64
    });

    // forge-lint: disable-next-line(unsafe-typecast)
    ctx.cumDistE6 += int256(uint256(lengthE6));
  }

  function _fillBids(
    address pool,
    uint256 token1ScaleMultiplier,
    uint256 referencePriceX64,
    uint256 baseSellFeeX64,
    uint256 notionalFeeE8,
    int16 curBinIdx,
    uint104 curPosInBin,
    int24 curBinDistFromProvidedPriceE6,
    int16 lowCap,
    DepthLevel[] memory bids
  ) internal view {
    int256 walkDistE6 = int256(curBinDistFromProvidedPriceE6);
    uint256 cumToken1Out;
    uint256 cumToken0Sold;
    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(notionalFeeE8));

    uint256 out;

    {
      (, uint104 t1, uint16 lengthE6,, uint16 addFeeSellE6) = PoolStateLibrary._binState(pool, curBinIdx);
      uint256 sellFeeX64 = FeeMath.binTotalFeeX64(baseSellFeeX64, addFeeSellE6, notionalFeeX64);

      uint256 lowerX64 = _priceFromReferenceAndDistE6(referencePriceX64, walkDistE6, Math.Rounding.Floor);
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 upperX64 =
        _priceFromReferenceAndDistE6(referencePriceX64, walkDistE6 + int256(uint256(lengthE6)), Math.Rounding.Floor);

      uint256 amountScaled = Math.mulDiv(uint256(t1), uint256(curPosInBin), MAX_POS_U104, Math.Rounding.Floor);
      uint256 mStartX64 =
        SwapMath.calculatePriceAtBinPosition(lowerX64, upperX64, uint256(curPosInBin), Math.Rounding.Floor);
      uint256 mEndX64 = lowerX64;
      uint256 amountExternal = _toExternal(amountScaled, token1ScaleMultiplier);

      (uint256 binAvg, uint256 newCumToken1Out, uint256 newCumToken0Sold) =
        _accumulateBidLevel(sellFeeX64, amountExternal, mStartX64, mEndX64, cumToken1Out, cumToken0Sold);

      bids[out++] = DepthLevel({
        binIdx: curBinIdx,
        amountInBin: amountExternal,
        amountCumulative: newCumToken1Out,
        binAvgExecPriceX64: binAvg,
        cumulativeAvgExecPriceX64: _bidCumulativeAvgExecPriceX64(newCumToken1Out, newCumToken0Sold)
      });

      cumToken1Out = newCumToken1Out;
      cumToken0Sold = newCumToken0Sold;
    }

    for (int256 b = int256(curBinIdx) - 1; b >= int256(lowCap); b--) {
      // forge-lint: disable-next-line(unsafe-typecast)
      int16 binIdx = int16(b);
      // forge-lint: disable-next-line(unsafe-typecast)
      (,, uint16 lenAbove,,) = PoolStateLibrary._binState(pool, int16(b + 1));
      // forge-lint: disable-next-line(unsafe-typecast)
      walkDistE6 -= int256(uint256(lenAbove));

      (, uint104 t1, uint16 lengthE6,, uint16 addFeeSellE6) = PoolStateLibrary._binState(pool, binIdx);
      uint256 sellFeeX64 = FeeMath.binTotalFeeX64(baseSellFeeX64, addFeeSellE6, notionalFeeX64);

      uint256 lowerX64 = _priceFromReferenceAndDistE6(referencePriceX64, walkDistE6, Math.Rounding.Floor);
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 upperX64 =
        _priceFromReferenceAndDistE6(referencePriceX64, walkDistE6 + int256(uint256(lengthE6)), Math.Rounding.Floor);

      uint256 amountScaled = uint256(t1);
      uint256 mStartX64 = upperX64;
      uint256 mEndX64 = lowerX64;
      uint256 amountExternal = _toExternal(amountScaled, token1ScaleMultiplier);

      (uint256 binAvg, uint256 newCumToken1Out, uint256 newCumToken0Sold) =
        _accumulateBidLevel(sellFeeX64, amountExternal, mStartX64, mEndX64, cumToken1Out, cumToken0Sold);

      bids[out++] = DepthLevel({
        binIdx: binIdx,
        amountInBin: amountExternal,
        amountCumulative: newCumToken1Out,
        binAvgExecPriceX64: binAvg,
        cumulativeAvgExecPriceX64: _bidCumulativeAvgExecPriceX64(newCumToken1Out, newCumToken0Sold)
      });

      cumToken1Out = newCumToken1Out;
      cumToken0Sold = newCumToken0Sold;
    }
  }

  function _bidCumulativeAvgExecPriceX64(uint256 cumToken1Out, uint256 cumToken0Sold) internal pure returns (uint256) {
    if (cumToken0Sold == 0) return 0;
    return Math.mulDiv(cumToken1Out, Q64, cumToken0Sold, Math.Rounding.Floor);
  }
}
