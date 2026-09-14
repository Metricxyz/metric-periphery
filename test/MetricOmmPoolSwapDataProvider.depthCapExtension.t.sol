// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {LiquidityLadder} from "../contracts/libraries/LiquidityLadder.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {CapExtension} from "./mocks/extensions/CapExtension.sol";

/// @title MetricOmmPoolDataProvider depth ladder binary-search fallback
/// @notice Proves the ladder builder binary-searches around a size-dependent extension revert instead of
///         aborting when beforeSwap or afterSwap rejects amounts above a configured cap.
contract MetricOmmPoolDataProviderDepthCapExtensionTest is SimpleRouterTestBase {
  MetricOmmPoolDataProvider internal dataProvider;
  CapExtension internal capExtension;
  MetricOmmPool internal cappedPool;

  function setUp() public override {
    super.setUp();
    dataProvider = new MetricOmmPoolDataProvider(address(factoryStub));
    capExtension = new CapExtension();
    cappedPool = _deployCappedPool();
    _seedLiquidityPool(cappedPool, address(weth), address(token1), 2);
  }

  function test_getLiquidityDepthLive_stopsAtBinarySearchedCapWhenExtensionBlocksFurtherAsks() public {
    LiquidityLadder.LiquidityDepth memory uncapped = dataProvider.getLiquidityDepthLive(address(cappedPool), 4);
    assertGt(uncapped.asks.length, 0, "expected at least one ask row before capping");
    uint256 fullAskRoom = uncapped.asks[0].amountAvailableInBin;

    uint256 cap = fullAskRoom / 3;
    assertGt(cap, 0, "cap must be nonzero to be meaningful");
    capExtension.setCap(cap);

    LiquidityLadder.LiquidityDepth memory depth = dataProvider.getLiquidityDepthLive(address(cappedPool), 4);

    assertEq(depth.asks.length, 1, "ladder should stop at the capped bin instead of continuing past it");
    // 20 bisection probes over an initial [0, fullAskRoom] range converge to within fullAskRoom / 2**20 of the
    // true cap; bisection only ever keeps amounts that actually succeeded, so it can undershoot but never overshoot.
    assertLe(depth.asks[0].cumulativeOut, cap, "binary search must not overshoot the cap");
    assertGe(
      depth.asks[0].cumulativeOut,
      cap - fullAskRoom / (2 ** 20) - 1,
      "binary search should converge close to the cap within 20 iterations"
    );
  }

  function testFuzz_afterSwapOutputCap_limitsTradeableDepth(
    bool zeroForOne,
    bool hypothetical,
    bool capInNextBin,
    uint256 capBps
  ) public {
    capBps = bound(capBps, 1000, 9000);
    lpContract.addLiquidityRange(address(cappedPool), 3, -4, 4, 1e12);
    LiquidityLadder.LiquidityDepth memory initial = dataProvider.getLiquidityDepthLive(address(cappedPool), 4);
    _swapExactOutput(false, initial.asks[0].amountAvailableInBin * 2 / 5);

    LiquidityLadder.LiquidityDepth memory uncapped = _depth(hypothetical);
    LiquidityLadder.DepthLevel[] memory fullLevels = zeroForOne ? uncapped.bids : uncapped.asks;
    uint256 stopRow = capInNextBin ? 1 : 0;
    uint256 priorOutput = capInNextBin ? fullLevels[0].cumulativeOut : 0;
    uint256 binCapacity = fullLevels[stopRow].amountAvailableInBin;
    uint256 cap = priorOutput + binCapacity * capBps / 10_000;
    capExtension.setOutputCap(cap);

    LiquidityLadder.LiquidityDepth memory capped = _depth(hypothetical);
    LiquidityLadder.DepthLevel[] memory levels = zeroForOne ? capped.bids : capped.asks;
    assertEq(levels.length, stopRow + 1, "ladder must stop in the capped bin");
    uint256 tradeableSum;
    for (uint256 i; i < levels.length; i++) {
      assertEq(levels[i].binIdx, fullLevels[i].binIdx);
      assertEq(levels[i].amountAvailableInBin, fullLevels[i].amountAvailableInBin);
      if (i < stopRow) assertEq(levels[i].amountTradeableInBin, fullLevels[i].amountAvailableInBin);
      tradeableSum += levels[i].amountTradeableInBin;
      assertEq(levels[i].cumulativeOut, tradeableSum);
    }

    LiquidityLadder.DepthLevel memory last = levels[stopRow];
    assertLt(last.amountTradeableInBin, binCapacity);
    assertLe(last.cumulativeOut, cap, "tradeable output must not exceed the cap");
    // The search performs at most 20 bisections within the failing bin.
    uint256 tolerance = binCapacity / (2 ** 20) + 1;
    assertLe(cap - last.cumulativeOut, tolerance, "tradeable output must reach the cap within search precision");
    assertLe(cap - priorOutput - last.amountTradeableInBin, tolerance);

    vm.expectRevert(abi.encodeWithSelector(CapExtension.OutputCapExceeded.selector, cap + 1, cap));
    _swapExactOutput(zeroForOne, cap + 1);
    uint256 snapshot = vm.snapshotState();
    _swapExactOutput(zeroForOne, cap);
    assertTrue(vm.revertToState(snapshot));
    uint256 actualInput = _swapExactOutput(zeroForOne, last.cumulativeOut);
    assertEq(actualInput, last.cumulativeIn, "reported cumulative quote must be executable");
  }

  function _depth(bool hypothetical) internal returns (LiquidityLadder.LiquidityDepth memory) {
    if (hypothetical) {
      (uint128 bid, uint128 ask, uint128 referencePrice) = oracle.getQuote();
      return dataProvider.getLiquidityDepthHypothetical(address(cappedPool), 4, bid, ask, referencePrice);
    }
    return dataProvider.getLiquidityDepthLive(address(cappedPool), 4);
  }

  function _swapExactOutput(bool zeroForOne, uint256 amountOut) internal returns (uint256) {
    assertLe(amountOut, type(uint128).max);
    vm.prank(swapper);
    return router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(cappedPool),
        tokenIn: zeroForOne ? address(weth) : address(token1),
        tokenOut: zeroForOne ? address(token1) : address(weth),
        zeroForOne: zeroForOne,
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut: uint128(amountOut),
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: _priceLimit(zeroForOne),
        extensionData: hex""
      })
    );
  }

  function _deployCappedPool() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    extensions.extension1 = address(capExtension);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    extensionOrders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    deployed = new MetricOmmPool(
      address(factoryStub),
      address(weth),
      address(token1),
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_OPERATIONAL_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0,
      type(uint16).max
    );

    factoryStub.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("cappedAdminFeeDest"),
      address(this)
    );
  }
}
