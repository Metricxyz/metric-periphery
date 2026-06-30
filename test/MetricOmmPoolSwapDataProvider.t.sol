// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

/// forge-config: default.fuzz.runs = 128

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {MetricOmmPoolDataProviderTestBase} from "./MetricOmmPoolDataProviderTestBase.sol";

contract MetricOmmPoolDataProviderTest is MetricOmmPoolDataProviderTestBase {
  function setUp() public {}

  function test_constructorRevertsOnZeroFactory() public {
    vm.expectRevert(MetricOmmPoolDataProvider.InvalidFactory.selector);
    new MetricOmmPoolDataProvider(address(0));
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
    (MetricOmmPool pool,,,,, MetricOmmSimpleRouter router,,) =
      _deployCase(token0Decimals, token1Decimals, bidPriceX64, askPriceX64, warmupMode, 0, false);

    uint256 smallOut1 = _smallTradeAmount(token1Decimals);
    uint256 smallOut0 = _smallTradeAmount(token0Decimals);
    uint256 scale0 = _scaleMultiplierFromDecimals(token0Decimals);
    uint256 scale1 = _scaleMultiplierFromDecimals(token1Decimals);

    (uint128 quotedBidX64,) = IMetricOmmPool(pool).getSellAndBuyPrices();
    (uint256 outForToken0In, uint256 used0) = _swapExactOutputUntilNonZero(router, address(pool), true, smallOut1);
    uint256 realizedBidX64 = Math.mulDiv(outForToken0In * scale1, Q64, used0 * scale0, Math.Rounding.Floor);
    assertApproxEqRel(realizedBidX64, uint256(quotedBidX64), 0.03e18);

    (, uint128 quotedAskX64) = IMetricOmmPool(pool).getSellAndBuyPrices();
    (uint256 outForToken1In, uint256 used1) = _swapExactOutputUntilNonZero(router, address(pool), false, smallOut0);
    uint256 realizedAskX64 = Math.mulDiv(used1 * scale1, Q64, outForToken1In * scale0, Math.Rounding.Ceil);
    assertApproxEqRel(realizedAskX64, uint256(quotedAskX64), 0.03e18);
  }
}
