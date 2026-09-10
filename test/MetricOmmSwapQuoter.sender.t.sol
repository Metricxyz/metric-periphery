// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {SwapAllowlistExtension} from "../contracts/extensions/SwapAllowlistExtension.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmSwapQuoterSenderTest is SimpleRouterTestBase {
  SwapAllowlistExtension internal allowlist;
  MetricOmmPool internal gatedPool;

  function setUp() public override {
    super.setUp();
    allowlist = new SwapAllowlistExtension(address(factoryStub));
    gatedPool = _deployGatedPool();
    _seedLiquidityPool(gatedPool, address(weth), address(token1), 2);
    allowlist.setAllowedToSwap(address(gatedPool), address(router), true);
  }

  function test_liveQuote_asRouter_matchesSenderGatedSwap() public {
    vm.prank(address(router));
    (uint256 quotedIn, uint256 quotedOut) =
      quoter.quoteLiveExactInSingle(address(gatedPool), recipient, true, 2500, _priceLimit(true), hex"");
    assertEq(quotedIn, 2500);
    assertGt(quotedOut, 0);

    vm.prank(swapper);
    uint256 actualOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(gatedPool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 2500,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: _priceLimit(true),
        extensionData: hex""
      })
    );
    assertEq(actualOut, quotedOut);
  }

  function test_exactOutputQuotes_asRouter_matchLiveAndHypothetical() public {
    vm.prank(address(router));
    (uint256 liveIn, uint256 liveOut) =
      quoter.quoteLiveExactOutSingle(address(gatedPool), recipient, true, 1500, _priceLimit(true), hex"");
    vm.prank(address(router));
    (uint256 hypotheticalIn, uint256 hypotheticalOut) = quoter.quoteHypotheticalExactOutputSingle(
      address(gatedPool), recipient, true, 1500, _priceLimit(true), TEST_BID_X64, TEST_ASK_X64, TEST_BID_X64, hex""
    );
    assertGt(liveIn, 0);
    assertEq(liveOut, 1500);
    assertEq(hypotheticalIn, liveIn);
    assertEq(hypotheticalOut, liveOut);
  }

  function test_quote_rejectsUnapprovedSenderEvenWhenRecipientIsAllowed() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.WrappedError.selector,
        address(gatedPool),
        IMetricOmmPoolActions.simulateSwapAndRevert.selector,
        abi.encodeWithSelector(IMetricOmmPoolActions.NotAllowedToSwap.selector)
      )
    );
    vm.prank(swapper);
    quoter.quoteLiveExactInSingle(address(gatedPool), address(router), true, 2500, _priceLimit(true), hex"");
  }

  function _deployGatedPool() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    extensions.extension1 = address(allowlist);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

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
