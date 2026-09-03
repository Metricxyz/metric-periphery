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
/// @dev Off-chain queries only (`eth_call`); not `view` because the probes drive
///      `simulateSwapAndRevert`. `getLiquidityDepth` is authoritative about liquidity and silent about
///      permission: a `beforeSwap`/`afterSwap` extension can refuse a trade the curve says is fillable.
///
///      Probes must use `simulateSwapAndRevert`, not `MetricOmmSwapQuoter.quoteLive*`: the quoter
///      reverts inside `metricOmmSwapCallback`, which `swap` invokes *before* `_afterSwap`, so it never
///      observes an `afterSwap` refusal. `simulateSwapAndRevert` runs both phases and reverts after.
///
///      Two refusals are out of reach, and both are silent rather than erroring:
///
///      - A non-zero `pauseLevel`: `simulateSwapAndRevert` is not `whenNotPaused`, so a paused pool
///        simulates clean. Callers read it themselves.
///      - An identity gate. Probes reach the pool directly, so it sees `msg.sender` as this contract
///        and never a prospective trader — there is no parameter to carry one. Against a pool running
///        `SwapAllowlistExtension` (or anything else keying on `sender` in `beforeSwap`) the verdict
///        describes *this contract's* permission: both sides read closed if it is not allowlisted, and
///        the gate is trivially satisfied for everyone if it is. Neither is the answer a caller wants,
///        so treat results for such pools as unreliable rather than conservative.
contract MetricOmmPoolExecutableDepthProvider is MetricOmmPoolDataProvider {
  /// @notice `simulateSwapAndRevert` returned instead of reverting — not the pool we assume.
  error ExecutableProbeDidNotRevert();

  /// @notice Depth plus the executable prefix of each side.
  /// @dev Key on the amounts, not the counts. Amounts are token figures in the same units as
  ///      `DepthLevel.amountCumulative`, so a caller holding its own curve can locate them on it and cut
  ///      part-way through a level. The counts index into `depth` alone; a ladder built elsewhere (a
  ///      different window, different rounding) will not line up.
  struct ExecutableDepth {
    LiquidityDepth depth;
    /// @dev Largest token0 output executable on the buy side; `0` when the side is closed.
    uint256 asksExecutableAmountOut;
    /// @dev Largest token1 output executable on the sell side.
    uint256 bidsExecutableAmountOut;
    /// @dev Leading `depth.asks` levels that execute. Diagnostic; see the struct note.
    uint256 asksExecutableLevels;
    /// @dev Leading `depth.bids` levels that execute.
    uint256 bidsExecutableLevels;
    /// @dev Simulations spent on the ask side, for callers budgeting `eth_call` gas.
    uint256 asksProbes;
    /// @dev Simulations spent on the bid side.
    uint256 bidsProbes;
  }

  /// @dev Grouped to keep the search loop shallow under via-IR.
  struct ProbeEnv {
    address pool;
    bool zeroForOne;
    uint128 bidPriceX64;
    uint128 askPriceX64;
    uint128 referencePriceX64;
  }

  constructor(address factory) MetricOmmPoolDataProvider(factory) {}

  /// @notice Depth for `pool`, plus the executable prefix of each side, in one call.
  /// @dev Prices come from the snapshot, so probes run at the prices the returned curve was built from
  ///      and the call needs nothing from its caller but `pool`. Costs the depth walk plus one
  ///      simulation per side unobstructed, `log2(levels)` when something refuses.
  function getExecutableLiquidityDepth(address pool, uint8 maxBinsPerSide)
    external
    returns (ExecutableDepth memory out)
  {
    // Self-call: the walk is `external` on the base contract, and this keeps it untouched.
    out.depth = this.getLiquidityDepth(pool, maxBinsPerSide);

    // `asks` buys token0, so token1 goes in: `zeroForOne = false`.
    (out.asksExecutableLevels, out.asksExecutableAmountOut, out.asksProbes) = _executablePrefix(
      ProbeEnv({
        pool: pool,
        zeroForOne: false,
        bidPriceX64: out.depth.oracleBidX64,
        askPriceX64: out.depth.oracleAskX64,
        referencePriceX64: out.depth.oracleReferenceX64
      }),
      out.depth.asks
    );
    (out.bidsExecutableLevels, out.bidsExecutableAmountOut, out.bidsProbes) = _executablePrefix(
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

  /// @dev Largest `n` with levels `[0, n)` executable, plus that boundary's cumulative output.
  ///      Deepest level first, since that is the answer whenever nothing refuses. Monotonicity is the
  ///      pool's own — a larger trade moves it further — and where it fails the result is still a
  ///      prefix verified at its own boundary.
  function _executablePrefix(ProbeEnv memory env, DepthLevel[] memory levels)
    internal
    returns (uint256 executable, uint256 amountOut, uint256 probes)
  {
    uint256 count = levels.length;
    if (count == 0) return (0, 0, 0);

    if (_probe(env, levels[count - 1].amountCumulative)) {
      return (count, levels[count - 1].amountCumulative, 1);
    }
    probes = 1;

    // Levels below `lo` execute, `hi` does not. `lo` counts levels, not indices.
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

    // A verified boundary, never an interpolation: `lo == 0` means even the shallowest was refused.
    amountOut = lo == 0 ? 0 : levels[lo - 1].amountCumulative;
    return (lo, amountOut, probes);
  }

  /// @dev Whether the pool fills `amountOut` on this side, extensions included. Exact-output, so the
  ///      level's own figure is the target and no amount is derived. Only `SimulateSwap` with both
  ///      deltas non-zero counts as executable; any other revert is a refusal.
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
      revert ExecutableProbeDidNotRevert();
    } catch (bytes memory reason) {
      (int128 amount0Delta, int128 amount1Delta, bool matched) =
        MetricOmmSwapQuoteDecode.decodeSwapDeltas(reason, IMetricOmmPoolActions.SimulateSwap.selector);
      if (!matched) return false;
      return amount0Delta != 0 && amount1Delta != 0;
    }
  }
}
