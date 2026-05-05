// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// forge-config: default.fuzz.runs = 128

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmPoolSwapper} from "../contracts/MetricOmmPoolSwapper.sol";
import {IMetricOmmPoolSwapDataProvider} from "../contracts/interfaces/IMetricOmmPoolSwapDataProvider.sol";
import {MetricOmmPoolSwapDataProvider} from "../contracts/MetricOmmPoolSwapDataProvider.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";
import {MockPriceProviderSDH, SwapDataHelperTestBase} from "./SwapDataHelperTestBase.sol";

contract SwapDataHelperTest is SwapDataHelperTestBase {
  function setUp() public {}

  function test_constructorRevertsOnZeroFactory() public {
    vm.expectRevert(IMetricOmmPoolSwapDataProvider.InvalidFactory.selector);
    new MetricOmmPoolSwapDataProvider(address(0));
  }

  function test_getBestBidAndAsk_includesSpreadAndNotionalFees() public {
    (MetricOmmPool pool,,,, MetricOmmPoolSwapDataProvider helper,,,) =
      _deployCase(18, 18, uint128(Q64), uint128(Q64), 0, 0, false);
    (uint128 bidX64, uint128 askX64) = helper.getBestBidAndAsk(address(pool));
    assertGt(askX64, Q64);
    assertLt(bidX64, Q64);
  }

  function test_getBestBidAndAsk_matchesQuoteFormula() public {
    (
      MetricOmmPool pool,
      MockPriceProviderSDH oracle,,,
      MetricOmmPoolSwapDataProvider helper,,
      RouterTestFactory factoryStub,
    ) = _deployCase(18, 18, uint128(Q64), uint128(Q64), 0, 0, false);
    (uint128 bidX64, uint128 askX64) = helper.getBestBidAndAsk(address(pool));
    (uint256 expectedBid, uint256 expectedAsk) =
      _expectedBestBidAsk(address(pool), address(factoryStub), address(oracle));

    assertEq(askX64, expectedAsk);
    assertEq(bidX64, expectedBid);
  }

  function test_getBestBidAndAsk_revertsOnInvalidOraclePrices() public {
    (MetricOmmPool pool, MockPriceProviderSDH oracle,,, MetricOmmPoolSwapDataProvider helper,,,) =
      _deployCase(18, 18, uint128(Q64), uint128(Q64), 0, 0, false);
    oracle.setBidAndAskPrice(2, 1);
    vm.expectRevert(IMetricOmmPoolSwapDataProvider.InvalidOraclePrice.selector);
    helper.getBestBidAndAsk(address(pool));
  }

  function test_quotes_match_tiny_swaps_matrix() public {
    _runTinySwapSimilarityCase(18, 18, _toX64(980_000), _toX64(1_020_000), 0);
    _runTinySwapSimilarityCase(18, 17, _toX64(1_800_000), _toX64(1_840_000), 0);
    _runTinySwapSimilarityCase(18, 18, _toX64(700_000), _toX64(730_000), 0);
    _runTinySwapSimilarityCase(18, 18, _toX64(1_300_000), _toX64(1_360_000), 0);
  }

  function _runTinySwapSimilarityCase(
    uint8 token0Decimals,
    uint8 token1Decimals,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint8 warmupMode
  ) internal {
    (MetricOmmPool pool,,,, MetricOmmPoolSwapDataProvider helper, MetricOmmPoolSwapper router,,) =
      _deployCase(token0Decimals, token1Decimals, bidPriceX64, askPriceX64, warmupMode, 0, false);

    uint256 smallOut1 = _smallTradeAmount(token1Decimals);
    uint256 smallOut0 = _smallTradeAmount(token0Decimals);
    uint256 scale0 = _scaleMultiplierFromDecimals(token0Decimals);
    uint256 scale1 = _scaleMultiplierFromDecimals(token1Decimals);

    (uint128 quotedBidX64,) = helper.getBestBidAndAsk(address(pool));
    (uint256 outForToken0In, uint256 used0) = _swapExactOutputUntilNonZero(router, address(pool), true, smallOut1);
    uint256 realizedBidX64 = Math.mulDiv(outForToken0In * scale1, Q64, used0 * scale0, Math.Rounding.Floor);
    assertApproxEqRel(realizedBidX64, uint256(quotedBidX64), 0.03e18);

    (, uint128 quotedAskX64) = helper.getBestBidAndAsk(address(pool));
    (uint256 outForToken1In, uint256 used1) = _swapExactOutputUntilNonZero(router, address(pool), false, smallOut0);
    uint256 realizedAskX64 = Math.mulDiv(used1 * scale1, Q64, outForToken1In * scale0, Math.Rounding.Ceil);
    assertApproxEqRel(realizedAskX64, uint256(quotedAskX64), 0.03e18);
  }
}
