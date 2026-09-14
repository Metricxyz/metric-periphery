// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)
/// forge-config: default.fuzz.runs = 32

import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {LiquidityLadder} from "../contracts/libraries/LiquidityLadder.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";
import {
  LiquiditySeederForSwapData,
  MockPriceProviderSDH,
  MetricOmmPoolDataProviderTestBase
} from "./MetricOmmPoolDataProviderTestBase.sol";

/// @title MetricOmmPoolDataProvider liquidity depth integration tests
/// @notice Same P1/P2/A1/A2/A3 scenario at four `getLiquidityDepthLive` window sizes to compare gas (eth_call cost scales with ladder length).
/// @dev **P1** Full-range pool (`fullBinRange = true`, 256 bins with liquidity). **P2** One `_randomWalkSwaps` step per fuzz case. **A1** `getLiquidityDepthLive(pool, maxBinsPerSide)`.
///      **A2-A3** Cheap cumulative checks: first valid ladder rows (smallest cumulatives, bounded count) plus one largest feasible cumulative per side vs `simulateSwapAndRevert`, then reference bid/ask vs the same provider.
///      Four tests fix `maxBinsPerSide` to 4, 16, 64, and 255.
contract MetricOmmPoolDataProviderDepthTest is MetricOmmPoolDataProviderTestBase {
  uint256 internal constant DEEP_SHARES = SHARES_PER_BIN / 5_000;
  /// @dev Max number of earliest ladder rows (smallest cumulatives) to cross-check via simulate per side.
  uint256 internal constant MAX_LOWEST_ROW_SIM_CHECKS = 8;

  MetricOmmPool internal pool;
  MockPriceProviderSDH internal oracle;
  MockERC20 internal token0;
  MockERC20 internal token1;
  MetricOmmPoolDataProvider internal helper;
  MetricOmmSimpleRouter internal router;
  RouterTestFactory internal factory;
  LiquiditySeederForSwapData internal seeder;

  function setUp() public {
    (pool, oracle, token0, token1, helper, router, factory, seeder) =
      _deployCase(18, 18, _toX64(990_000), _toX64(1_010_000), 0, DEEP_SHARES, true);
  }

  function testFuzz_liquidityDepth_vsSimulate_maxBinsPerSide4(uint256 seed) public {
    _liquidityDepthVsSimulateScenario(seed, 4);
  }

  function testFuzz_liquidityDepth_vsSimulate_maxBinsPerSide16(uint256 seed) public {
    _liquidityDepthVsSimulateScenario(seed, 16);
  }

  function testFuzz_liquidityDepth_vsSimulate_maxBinsPerSide64(uint256 seed) public {
    _liquidityDepthVsSimulateScenario(seed, 64);
  }

  function testFuzz_liquidityDepth_vsSimulate_maxBinsPerSide255(uint256 seed) public {
    _liquidityDepthVsSimulateScenario(seed, 255);
  }

  function test_liquidityDepthLive_partialCurrentBin_asks() public {
    _assertPartialBinDepth(false, true);
  }

  function test_liquidityDepthHypothetical_partialCurrentBin_asks() public {
    _assertPartialBinDepth(false, false);
  }

  function test_liquidityDepthLive_partialCurrentBin_bids() public {
    _assertPartialBinDepth(true, true);
  }

  function test_liquidityDepthHypothetical_partialCurrentBin_bids() public {
    _assertPartialBinDepth(true, false);
  }

  function _assertPartialBinDepth(bool zeroForOne, bool live) internal {
    (, int16 initialBin,,,,,) = PoolStateLibrary._slot0(address(pool));
    (uint104 initialToken0,,,,) = PoolStateLibrary._binState(address(pool), initialBin);
    _routerExactOutput(router, address(pool), false, uint256(initialToken0) * 2 / 5);

    (, int16 currentBin, uint104 position,,,,) = PoolStateLibrary._slot0(address(pool));
    assertEq(currentBin, initialBin);
    assertGt(position, 0);
    assertLt(position, type(uint104).max);

    (uint128 bid, uint128 ask, uint128 referencePrice) = oracle.getQuote();
    LiquidityLadder.LiquidityDepth memory depth = live
      ? helper.getLiquidityDepthLive(address(pool), 2)
      : helper.getLiquidityDepthHypothetical(address(pool), 2, bid, ask, referencePrice);
    LiquidityLadder.DepthLevel[] memory levels = zeroForOne ? depth.bids : depth.asks;
    assertGe(levels.length, 2);

    uint256 cumulativeOut;
    for (uint256 i; i < 2; i++) {
      int16 expectedBin = currentBin + (zeroForOne ? -int16(uint16(i)) : int16(uint16(i)));
      assertEq(levels[i].binIdx, expectedBin);
      (uint104 token0Before, uint104 token1Before,,,) = PoolStateLibrary._binState(address(pool), expectedBin);
      uint256 remaining = zeroForOne ? token1Before : token0Before;
      assertGt(remaining, 0);
      assertEq(levels[i].amountAvailableInBin, remaining, "depth must include the full remaining balance");
      assertEq(levels[i].amountTradeableInBin, remaining, "without extensions, tradeable is equal to available");
      cumulativeOut += remaining;
      assertEq(levels[i].cumulativeOut, cumulativeOut, "cumulative is the sum of previous and current available");
      _routerExactOutput(router, address(pool), zeroForOne, levels[i].amountTradeableInBin);
      (uint104 token0After, uint104 token1After,,,) = PoolStateLibrary._binState(address(pool), expectedBin);
      assertEq(zeroForOne ? token1After : token0After, 0, "trading a full row must exhaust its bin");
    }
  }

  function _liquidityDepthVsSimulateScenario(uint256 seed, uint8 maxBinsPerSide) internal {
    _randomWalkSwaps(router, address(pool), 18, 18, seed, 1);

    (uint128 bidOracle, uint128 askOracle,) = oracle.getQuote();
    LiquidityLadder.LiquidityDepth memory depth = helper.getLiquidityDepthLive(address(pool), maxBinsPerSide);

    uint256 runningAsk;
    uint256 runningBid;

    for (uint256 i; i < depth.asks.length; i++) {
      runningAsk += depth.asks[i].amountTradeableInBin;
      assertEq(depth.asks[i].cumulativeOut, runningAsk, "ask ladder cumulative mismatch");
    }

    for (uint256 j; j < depth.bids.length; j++) {
      runningBid += depth.bids[j].amountTradeableInBin;
      assertEq(depth.bids[j].cumulativeOut, runningBid, "bid ladder cumulative mismatch");
    }

    _assertLadderCumulativeSimsCheap(
      address(pool), bidOracle, askOracle, depth.asks, false, type(uint128).max, MAX_LOWEST_ROW_SIM_CHECKS
    );
    _assertLadderCumulativeSimsCheap(
      address(pool), bidOracle, askOracle, depth.bids, true, 0, MAX_LOWEST_ROW_SIM_CHECKS
    );

    (uint256 refBid, uint256 refAsk) = _expectedBestBidAsk(address(pool), address(factory), address(oracle));
    assertEq(refBid, depth.effectiveCurrentBidX64);
    assertEq(refAsk, depth.effectiveCurrentAskX64);
  }

  /// @notice Bounded-cost cross-check: first `maxLowestRowsToCheck` valid rows (smallest cumulatives) + one largest valid cumulative.
  function _assertLadderCumulativeSimsCheap(
    address poolAddr,
    uint128 bidOracle,
    uint128 askOracle,
    LiquidityLadder.DepthLevel[] memory levels,
    bool zeroForOne,
    uint128 priceLimitX64,
    uint256 maxLowestRowsToCheck
  ) internal {
    uint256 maxAmt = uint256(uint128(type(int128).max));
    uint256 n = levels.length;

    uint256 picked;
    for (uint256 i; i < n && picked < maxLowestRowsToCheck; i++) {
      uint256 cum = levels[i].cumulativeOut;
      if (cum == 0 || cum > maxAmt) continue;
      _simulateAndAssertCumulative(poolAddr, bidOracle, askOracle, zeroForOne, priceLimitX64, cum);
      unchecked {
        ++picked;
      }
    }

    uint256 bestCum;
    bool haveBest;
    for (uint256 j; j < n; j++) {
      uint256 c = levels[j].cumulativeOut;
      if (c == 0 || c > maxAmt) continue;
      if (!haveBest || c > bestCum) {
        bestCum = c;
        haveBest = true;
      }
    }
    if (haveBest) {
      _simulateAndAssertCumulative(poolAddr, bidOracle, askOracle, zeroForOne, priceLimitX64, bestCum);
    }
  }

  function _simulateAndAssertCumulative(
    address poolAddr,
    uint128 bidOracle,
    uint128 askOracle,
    bool zeroForOne,
    uint128 priceLimitX64,
    uint256 cum
  ) internal {
    uint128 cumU128 = uint128(cum);
    int128 amountSpecified = -int128(int256(uint256(cumU128)));
    (bool ok, int256 a0c, int256 a1c) =
      _trySimulateSwapDeltas(poolAddr, zeroForOne, amountSpecified, bidOracle, askOracle, priceLimitX64);
    assertTrue(ok, "simulate did not return SimulateSwap payload");

    if (zeroForOne) {
      assertTrue(a1c <= 0, "bid cumulative: pool token1 delta");
      assertApproxEqRel(uint256(-a1c), cum, MAX_REL_ERR_0_001_BPS, "bid cumulative");
    } else {
      assertTrue(a0c <= 0, "ask cumulative: pool token0 delta");
      assertApproxEqRel(uint256(-a0c), cum, MAX_REL_ERR_0_001_BPS, "ask cumulative");
    }
  }
}
