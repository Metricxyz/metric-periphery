// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricOmmPoolDataProvider} from "./MetricOmmPoolDataProvider.sol";
import {MetricOmmSwapInputs} from "../libraries/MetricOmmSwapInputs.sol";
import {MetricOmmSwapPath} from "../libraries/MetricOmmSwapPath.sol";
import {MetricOmmSwapQuoteDecode} from "../libraries/MetricOmmSwapQuoteDecode.sol";

/// @title MetricOmmPoolExecutableDepthProvider
/// @notice `getLiquidityDepth` plus how much of each side the pool will actually execute.
/// @dev For off-chain queries only (`eth_call`); not `view`, because the probes below drive
///      `simulateSwapAndRevert`, which mutates and then reverts.
///
///      `getLiquidityDepth` walks the pool's bins through the same `SwapMath` the pool uses, so it is
///      authoritative about *liquidity*. It is silent about *permission*: a pool may attach an extension
///      to `beforeSwap` or `afterSwap`, and those can reject a trade the curve says is fillable. The
///      consequence is not hypothetical — Base AERO/USDC carried an `OracleValueStopLoss` on `afterSwap`
///      that refused every swap above roughly one AERO while the published curve showed the full range,
///      so aggregators routed into it and their transactions reverted.
///
///      Two entrypoints could answer "will this actually execute", and only one of them works:
///
///      - `MetricOmmSwapQuoter.quoteLive*` drives the real `pool.swap` and reverts inside
///        `metricOmmSwapCallback` to recover the deltas. But `swap` invokes the callback *before*
///        `_afterSwap`, so that revert unwinds the call before any `afterSwap` extension has run. It
///        sees `beforeSwap` refusals and is structurally blind to the other half.
///      - `simulateSwapAndRevert` runs `_beforeSwap`, the swap, and `_afterSwap`, and only then reverts
///        with `SimulateSwap`. It is the sole entrypoint that observes both phases, which is why every
///        probe here uses it.
///
///      Prices come from the depth snapshot rather than a second provider read, so the probes are
///      evaluated at exactly the prices the returned curve was built from. Probing walks the level
///      ladder rather than raw token amounts: each level already carries the cumulative *output* it
///      represents, so an exact-output probe needs no unit conversion and inherits the pool's own
///      rounding.
///
///      A non-zero `pauseLevel` is deliberately not probed for. `swap` is `whenNotPaused` and
///      `simulateSwapAndRevert` is not, so a paused pool simulates clean and no probe here could see
///      it; callers must read `pauseLevel` themselves.
contract MetricOmmPoolExecutableDepthProvider is MetricOmmPoolDataProvider {
  // ============ Errors ============

  /// @notice `simulateSwapAndRevert` returned instead of reverting — the pool is not what we think it is.
  error ExecutableProbeDidNotRevert();

  // ============ Types ============

  /// @notice A depth snapshot alongside how much of each side is executable.
  /// @param depth The curve exactly as `getLiquidityDepth` returns it, untruncated.
  /// @param asksExecutable Number of leading `depth.asks` levels that execute. `0` means the buy side
  ///        is closed; `depth.asks.length` means the whole published side is good.
  /// @param bidsExecutable Number of leading `depth.bids` levels that execute.
  /// @param asksProbes Probes spent on the ask side, for callers budgeting `eth_call` gas.
  /// @param bidsProbes Probes spent on the bid side.
  struct ExecutableDepth {
    LiquidityDepth depth;
    uint256 asksExecutable;
    uint256 bidsExecutable;
    uint256 asksProbes;
    uint256 bidsProbes;
  }

  /// @dev Probe context, kept in one struct so the search loop stays shallow under via-IR.
  struct ProbeEnv {
    address pool;
    bool zeroForOne;
    uint128 bidPriceX64;
    uint128 askPriceX64;
    uint128 referencePriceX64;
  }

  // ============ Constructor ============

  constructor(address factory) MetricOmmPoolDataProvider(factory) {}

  // ============ External: executable depth ============

  /// @notice Depth for `pool`, plus the executable prefix of each side.
  /// @dev One `eth_call`. Cost is the depth walk plus at most `log2(levels) + 1` simulations per side —
  ///      and exactly one per side in the common case, where the deepest level executes and the search
  ///      exits immediately.
  /// @param pool Pool to read.
  /// @param maxBinsPerSide Depth window, as `getLiquidityDepth` takes it.
  function getExecutableLiquidityDepth(address pool, uint8 maxBinsPerSide)
    external
    returns (ExecutableDepth memory out)
  {
    // External self-call: the depth walk is `external` on the base contract. Harmless here (this is
    // never in a transaction path) and it keeps the audited walk untouched.
    out.depth = this.getLiquidityDepth(pool, maxBinsPerSide);

    // `asks` is buying token0, so token1 goes in: `zeroForOne = false`. `bids` is the reverse.
    (out.asksExecutable, out.asksProbes) = _executablePrefix(
      ProbeEnv({
        pool: pool,
        zeroForOne: false,
        bidPriceX64: out.depth.oracleBidX64,
        askPriceX64: out.depth.oracleAskX64,
        referencePriceX64: out.depth.oracleReferenceX64
      }),
      out.depth.asks
    );
    (out.bidsExecutable, out.bidsProbes) = _executablePrefix(
      ProbeEnv({
        pool: pool,
        zeroForOne: true,
        bidPriceX64: out.depth.oracleBidX64,
        askPriceX64: out.depth.oracleAskX64,
        referencePriceX64: out.depth.oracleReferenceX64
      }),
      out.depth.bids
    );
  }

  // ============ Internal: executable-prefix search ============

  /// @dev Largest `n` such that levels `[0, n)` execute, found by binary search over level indices.
  ///
  ///      Searching indices rather than token amounts is what makes this cheap and exact: the level's
  ///      own `amountCumulative` becomes the probe's target output, so no amount is ever derived or
  ///      rounded on the way in.
  ///
  ///      The deepest level is tried first because that is the answer whenever nothing is refusing —
  ///      the overwhelmingly common case, and it costs one simulation. Only a refusal there pays for
  ///      the halving.
  ///
  ///      Monotonicity is assumed, and it is the pool's own: a larger trade moves the pool further, so
  ///      an extension that refuses at size X refuses above it. Where that does not hold the result is
  ///      still a prefix that was verified to execute at its own boundary, which is the conservative
  ///      direction.
  function _executablePrefix(ProbeEnv memory env, DepthLevel[] memory levels)
    internal
    returns (uint256 executable, uint256 probes)
  {
    uint256 count = levels.length;
    if (count == 0) return (0, 0);

    if (_probe(env, levels[count - 1].amountCumulative)) return (count, 1);
    probes = 1;

    // Invariant: levels below `lo` execute, `hi` does not. `lo` counts levels, not indices.
    uint256 lo = 0;
    uint256 hi = count - 1;
    while (lo < hi) {
      uint256 mid = lo + (hi - lo) / 2;
      probes++;
      if (_probe(env, levels[mid].amountCumulative)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (lo, probes);
  }

  /// @dev Whether the pool fills `amountOut` on this side, extensions included.
  ///
  ///      Exact-output, so the target is the level's own cumulative figure with no conversion. A zero
  ///      target is treated as not executable: there is no trade to ask about, and the pool rejects a
  ///      zero `amountSpecified` outright.
  ///
  ///      Reverting with `SimulateSwap` and both deltas non-zero is the only success. Any other revert
  ///      is a refusal — an extension, a price bound, or liquidity — and `SimulateSwap` carrying a zero
  ///      delta means nothing filled. Neither is distinguished, because the caller only needs to know
  ///      where the executable prefix ends.
  function _probe(ProbeEnv memory env, uint256 amountOut) internal returns (bool) {
    if (amountOut == 0) return false;

    int128 amountSpecified = MetricOmmSwapInputs.asAmountSpecifiedOut(MetricOmmSwapInputs.toUint128(amountOut));

    try IMetricOmmPool(env.pool)
      .simulateSwapAndRevert(
        address(this),
        env.zeroForOne,
        amountSpecified,
        MetricOmmSwapPath.openLimit(env.zeroForOne),
        env.bidPriceX64,
        env.askPriceX64,
        env.referencePriceX64,
        hex""
      ) {
      // `simulateSwapAndRevert` always reverts. Returning means the target is not the pool we assume,
      // and treating that as a healthy fill would publish depth on the strength of a bad assumption.
      revert ExecutableProbeDidNotRevert();
    } catch (bytes memory reason) {
      (int128 amount0Delta, int128 amount1Delta, bool matched) =
        MetricOmmSwapQuoteDecode.decodeSwapDeltas(reason, IMetricOmmPoolActions.SimulateSwap.selector);
      if (!matched) return false;
      return amount0Delta != 0 && amount1Delta != 0;
    }
  }
}
