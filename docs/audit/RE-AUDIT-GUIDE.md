# metric-periphery — re-audit guide

Companion document: `metric-core/docs/audit/RE-AUDIT-GUIDE.md`. Read that one first — several
periphery findings were fixed on the core side, and the two ranges are paired.

## 1. Scope

| | commit | date |
|---|---|---|
| **Baseline** (last audited state) | `0069084b927ebe891c6e7712c459ce4ac7e3118f` | 2026-06-04 |
| **Head** (review this) | `6bb01830399a18c559067d53b73c749d89d7bd8d` (`main`) | 2026-08-27 |

```bash
git diff 0069084b927ebe891c6e7712c459ce4ac7e3118f..6bb01830399a18c559067d53b73c749d89d7bd8d
```

44 commits. The `lib/metric-core` submodule pin moves exactly in step with the core review range:

| | `lib/metric-core` pin |
|---|---|
| at baseline | `6aa6c3b` — the core baseline |
| at head | `0069abb` — the core head |

So the two documents cover a single, self-consistent change set with no gap between them.

## 2. How much changed

`83 files changed, +6569 / −3376`. Contracts: **+2731 / −1982**. Tests: **+3724 / −1350**.

**This is not a delta on the previously audited periphery. The router, quoter and extension layers
were rebuilt.** Set expectations accordingly.

**Deleted outright (previously audited, now gone):**

| File | LOC removed |
|---|---|
| `MetricOmmPoolSwapper.sol` | 835 |
| `interfaces/IMetricOmmPoolSwapper.sol` | 235 |
| `hooks/subhooks/OracleValueStopLossSubhook.sol` | 168 |
| `hooks/base/BaseMetricHook.sol` | 90 |
| `hooks/subhooks/PriceVelocityGuardSubhook.sol` | 77 |
| `common/MetricOmmPoolQuoter.sol` | 76 |
| `hooks/subhooks/{SwapReporter,SwapAllowlist,DepositAllowlist}Subhook.sol` + `SubhookUtils.sol` | 146 |

**New, never audited (fresh scope — the bulk of the review effort):**

| File | LOC |
|---|---|
| `lens/MetricOmmSwapQuoter.sol` | 376 |
| `extensions/OracleValueStopLossExtension.sol` | 363 |
| `MetricOmmSimpleRouter.sol` | 246 |
| `interfaces/IMetricOmmSwapQuoter.sol` | 193 |
| `interfaces/IMetricOmmSimpleRouter.sol` | 177 |
| `extensions/base/BaseMetricExtension.sol` | 108 |
| `libraries/TransientCallbackPool.sol` | 105 |
| `extensions/PriceVelocityGuardExtension.sol` | 95 |
| `base/MetricOmmSwapRouterBase.sol` | 95 |
| `base/PeripheryPayments.sol` | 94 |
| `libraries/MetricOmmSwap{Results,Path,Inputs,QuoteDecode}.sol` | 204 |
| `base/SelfPermit.sol` + `ISelfPermit.sol` | 74 |
| `extensions/{Swap,Deposit}AllowlistExtension.sol` | 93 |

**Modified:** `MetricOmmPoolLiquidityAdder.sol` (+114/−30), `lens/MetricOmmPoolDataProvider.sol`
(+113/−188), `MetricOmmPoolStateView.sol` (moved `lens/` → `common/`, +12/−14).

**Honest assessment.** Treat this as a **new audit of the periphery**, not a re-check. Only
`MetricOmmPoolLiquidityAdder`, `MetricOmmPoolDataProvider` and `MetricOmmPoolStateView` are
meaningfully reviewable as diffs. Everything in the table above is new code that has never been
looked at, including the entire payment/callback path (`PeripheryPayments`, `TransientCallbackPool`,
native-ETH handling) and the full multihop quoting surface.

## 3. Audit fixes — May private audit (`sherlock-audit/2026-05-metric-may-22nd`)

Periphery-scope findings only. See the core guide for #85–#97, #101–#102, #105–#107, #111–#113,
#116–#120; #103, #109, #121–#125, #127 are oracle-repo scope.

| # | Sev | Finding | Fix commit on `main` |
|---|---|---|---|
| 84 | Med | `addLiquidityWeighted` has no output-side guard, enabling an LP sandwich | `9d9814a`, then `82c133f` (`BinPositionBounds`) |
| 98 | Low | Swap router does not validate the target pool against the factory | `9d9814a`, `d764896`, `e161cb0` |
| 99 | Low | Raw `swap()` provides no amount-based slippage protection | `9d9814a` |
| 100 | Low | Liquidity-add router does not validate the target pool against the factory | `9d9814a`, then `6e0fbfa` |
| 104 | **High** | Router accepts an unverified pool address, letting a malicious pool drain user token allowances | `d764896` (+ `e161cb0`) |
| 108 | Low | `PriceVelocityGuardExtension` uses arithmetic mid instead of geometric mid | `02336db` |
| 110 | Low | `BaseMetricExtension` `onlyPool` check is spoofable | `409c7bf` (+ `a468af8` documents the deliberate omissions) |
| 112 | Low | Uncommon price-limit input design | `0991527` (open-limit sentinel normalisation) |
| 114 | Low | Data providers are using the wrong spread fee | `d35b204` |
| 115 | GH | Deposit allowlist has no whitelist-only period end handling | `a419a2c` (`allowAllDepositors` / `allowAllSwappers`) |

Note that **#104 was the single High of the May audit** and its fix (`d764896`) landed inside the
router rewrite — the fixed code is not the audited code. Re-verify against the current
`MetricOmmSimpleRouter` + `TransientCallbackPool`, not against the diff.

## 4. Audit fixes — July public contest (`sherlock-audit/2026-07-metric-judging`)

~3,900 submissions, mostly duplicates or invalid. **32 issues carry `Will Fix`**; thirteen of
those are periphery scope:

| # | Finding | Fix commit on `main` | Status |
|---|---|---|---|
| 120 | Attacker blocks valid swaps in velocity-guarded pools with no-delta swaps | core `fef8dae` + `f639843` | fixed (core rejects zero-delta; guard uses a fixed per-block anchor) |
| 174 | Stop-loss decay truncation bypasses LP protection for small bins | `2b7fdcb` | fixed |
| 257 | Watermark decay halted via frequent tiny swaps (integer truncation) | `2b7fdcb` (E8 `uint32` → E18 `uint64`) | fixed |
| 262 | Integer truncation in linear decay permanently freezes watermark decay | `2b7fdcb` | fixed |
| 554 | Continued swaps permanently freeze one direction of a stop-loss pool | `2b7fdcb` + `8fc2a75` | fixed |
| 1508 | `IMetricOmmSimpleRouter` NatSpec inconsistent with its own implementation | `4ad7286` | fixed (docs) |
| 1694 | Valid `uint256` position shares make both StateView getters revert above `uint104.max` | `1f38b52` | fixed |
| 1761 | `MetricOmmPoolLiquidityAdder` does not validate pool against factory | `6e0fbfa` | fixed |
| 2242 | Same as #1761 — malicious pool can drain tokens up to max caps | `6e0fbfa` | fixed |
| 2932 | `addLiquidityWeighted()` cursor bounds insufficient against arbitrage | `82c133f` + core `dbca2f9` | fixed |
| 2952 | `addLiquidityExactShares()` has no cursor bounds | `82c133f` | fixed |
| 3048 | Stop-loss checks can miss a 10% drawdown in a normal USDC/WBTC pool | `8fc2a75` (metric scale 1e6 → 1e18) | fixed |
| 3735 | `MetricOmmPoolStateView.positionBinShares` truncates shares to `uint104` | `1f38b52` | fixed (duplicate of #1694) |

Related commits driven by contest findings the sponsor did **not** formally accept:

| # | Finding | Commit | Status |
|---|---|---|---|
| 2425 | Velocity guard bypass via same-block swap splitting | `f639843` | fixed anyway (fixed per-block mid anchor) |
| 2899 | `_clampMetric` saturation weakens stop-loss | `8fc2a75` | **partial** — scale raised 1e6 → 1e18; the `uint104` clamp remains |
| 1110 | Stop-loss decay clock reset via mismatched swaps | `2b7fdcb` | **partial** — covered by the decay rework, no dedicated fix |
| 3575 | Last LP sandwiches an exact-share deposit | `82c133f` | **partial** — bounds hardening only |
| 1686 | Large stop-loss timelocks wrap into elapsed deadlines | `eefb6c7` | fixed (`uint32` → `uint40` timestamps/timelocks) |
| 78 / 1242 / 1760 / 2365 / 2481 | Stop-loss uses arithmetic instead of geometric mid | `668bc63` | changed to bid/ask-based watermark calculation — **not** the geometric mid these findings asked for; confirm the new basis is sound |

**~90 findings are `Sponsor Confirmed` + `Won't Fix`** and are deliberately not addressed —
notably the permissionless `refundETH` / `sweepToken` family (#253, #523, #811, #3227), allowlist
bypass by routing through an allowlisted router (#225, #542), unbounded intermediate-hop input in
multihop routes (#3099, #3189), and the live quoter reverting upstream of `_afterSwap` so
afterSwap-reverting extensions stay invisible to `quoteLive*` (#3081, #3130). Out of scope here,
but worth knowing they are known.

## 5. New features and refactors — fresh review needed

| Commit(s) | Change |
|---|---|
| `81a64f2`, `b61fb80`, `9511427` | **Router consolidation.** `MetricOmmPoolSwapper` and `MetricOmmPoolQuoter` deleted; everything moves into `MetricOmmSimpleRouter` with `PeripheryPayments` (WETH deposit/unwrap/sweep/refund/pay), delegatecall multicall, and four extracted swap libraries. |
| `4fb2b28`, `4713a21`, `a41d384`, `dccbda7` | **New quoter.** `MetricOmmSwapQuoter` lens quotes off-chain via callback revert. Multihop live + hypothetical exact-in/exact-out APIs; partial-fill guards; `InvalidInputAmountAtHop`; disconnected-pool rejection. |
| `c1c545d`, `db2d731` | **Native ETH paths.** Mixed native + wrapped-WETH payment in one swap; native ETH liquidity funding in `MetricOmmPoolLiquidityAdder` with same-tx reclaim. |
| `52d9d83`, `cc8fef9` | **Subhooks → standalone extensions.** Composable subhook model replaced by standalone extension contracts, then renamed hooks → extensions to match core. |
| `a419a2c` | `allowAllDepositors` / `allowAllSwappers` bypass flags on the allowlist extensions. |
| `668bc63`, `eefb6c7`, `8fc2a75` | Stop-loss reworked: bid/ask-based watermarks, `uint40` timestamps, 1e18 metric scale. |
| `0991527` | Open price-limit sentinel (`0` = unconstrained) normalised in router and quoter. |
| `d35b204`, `8ac2e18` | `MetricOmmPoolDataProvider` spread-fee quoting realigned to core `SwapMath`; duplicate bid/ask pricing removed. |
| `d210a84`, `1b0d154`, `297b49f` | Licensing: extensions relicensed BUSL-1.1 → MIT; SPDX headers added. |
| `90039f9` | Git hooks split — pre-commit formats, pre-push runs the full suite. |

## 6. Suggested review order

1. `MetricOmmSimpleRouter.sol` + `base/PeripheryPayments.sol` + `libraries/TransientCallbackPool.sol` —
   entirely new, holds user funds, and carries the fix for the May High (#104).
2. `lens/MetricOmmSwapQuoter.sol` + the four `MetricOmmSwap*` libraries — new, and the multihop
   partial-fill / disconnected-path guards are the security-relevant part.
3. `extensions/OracleValueStopLossExtension.sol` — new file, and the target of the largest cluster
   of contest findings (#174, #257, #262, #554, #1110, #2899, #3048).
4. `extensions/base/BaseMetricExtension.sol` + `PriceVelocityGuardExtension.sol` — new, plus
   `a468af8` documents where `onlyPool` is deliberately omitted; verify that reasoning.
5. `MetricOmmPoolLiquidityAdder.sol` — diff-reviewable; factory registration (`6e0fbfa`) and
   `BinPositionBounds` (`82c133f`).
6. `lens/MetricOmmPoolDataProvider.sol`, `common/MetricOmmPoolStateView.sol` — diff-reviewable.
