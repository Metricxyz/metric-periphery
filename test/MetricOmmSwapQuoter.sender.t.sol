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
  MetricOmmPool internal gatedPool12;

  function setUp() public override {
    super.setUp();
    allowlist = new SwapAllowlistExtension(address(factoryStub));
    gatedPool = _deployGatedPool(address(weth), address(token1));
    gatedPool12 = _deployGatedPool(address(token1), address(token2));
    _seedLiquidityPool(gatedPool12, address(token1), address(token2), 3);
    allowlist.setAllowedToSwap(address(gatedPool12), address(router), true);
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

  function testFuzz_single_explicitSenderOverridesCaller(bool hypothetical, bool exactOut) public {
    vm.prank(swapper);
    (uint256 amountIn, uint256 amountOut) = _quoteSingleContext(address(router), hypothetical, exactOut);
    assertGt(amountIn, 0);
    assertGt(amountOut, 0);
  }

  function testFuzz_single_zeroSenderDefaultsToCaller(bool hypothetical, bool exactOut) public {
    vm.prank(address(router));
    (uint256 amountIn, uint256 amountOut) = _quoteSingleContext(address(0), hypothetical, exactOut);
    assertGt(amountIn, 0);
    assertGt(amountOut, 0);
  }

  function testFuzz_single_explicitUnapprovedSenderIsNotReplaced(bool hypothetical, bool exactOut) public {
    _expectSenderDenied(address(gatedPool));
    vm.prank(address(router));
    _quoteSingleContext(swapper, hypothetical, exactOut);
  }

  function testFuzz_multihop_explicitSenderReachesBothPools(bool hypothetical, bool exactOut) public {
    vm.prank(swapper);
    (uint256 amountIn, uint256 amountOut) = _quoteMultiContext(address(router), hypothetical, exactOut);
    assertGt(amountIn, 0);
    assertGt(amountOut, 0);
  }

  function testFuzz_multihop_zeroSenderDefaultsToCaller(bool hypothetical, bool exactOut) public {
    vm.prank(address(router));
    (uint256 amountIn, uint256 amountOut) = _quoteMultiContext(address(0), hypothetical, exactOut);
    assertGt(amountIn, 0);
    assertGt(amountOut, 0);
  }

  function testFuzz_multihop_explicitUnapprovedSenderIsNotReplaced(bool hypothetical, bool exactOut) public {
    _expectSenderDenied(exactOut ? address(gatedPool12) : address(gatedPool));
    vm.prank(address(router));
    _quoteMultiContext(swapper, hypothetical, exactOut);
  }

  function _expectSenderDenied(address target) internal {
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.WrappedError.selector,
        target,
        IMetricOmmPoolActions.simulateSwapAndRevert.selector,
        abi.encodeWithSelector(IMetricOmmPoolActions.NotAllowedToSwap.selector)
      )
    );
  }

  function _quoteSingleContext(address sender, bool hypothetical, bool exactOut) internal returns (uint256, uint256) {
    if (hypothetical) {
      if (exactOut) {
        return quoter.quoteHypotheticalExactOutputSingle(
          address(gatedPool),
          sender,
          recipient,
          true,
          1500,
          _priceLimit(true),
          TEST_BID_X64,
          TEST_ASK_X64,
          TEST_BID_X64,
          hex""
        );
      }
      return quoter.quoteHypotheticalExactInputSingle(
        address(gatedPool),
        sender,
        recipient,
        true,
        2500,
        _priceLimit(true),
        TEST_BID_X64,
        TEST_ASK_X64,
        TEST_BID_X64,
        hex""
      );
    }
    if (exactOut) {
      return quoter.quoteLiveExactOutSingle(address(gatedPool), sender, recipient, true, 1500, _priceLimit(true), hex"");
    }
    return quoter.quoteLiveExactInSingle(address(gatedPool), sender, recipient, true, 2500, _priceLimit(true), hex"");
  }

  function _quoteMultiContext(address sender, bool hypothetical, bool exactOut) internal returns (uint256, uint256) {
    address[] memory pools = new address[](2);
    pools[0] = address(gatedPool);
    pools[1] = address(gatedPool12);
    bytes[] memory extensionDatas = new bytes[](2);
    if (hypothetical) {
      uint128[] memory bids = new uint128[](2);
      uint128[] memory asks = new uint128[](2);
      uint128[] memory refs = new uint128[](2);
      for (uint256 i; i < 2; i++) {
        bids[i] = TEST_BID_X64;
        asks[i] = TEST_ASK_X64;
        refs[i] = TEST_BID_X64;
      }
      if (exactOut) {
        return quoter.quoteHypotheticalExactOutput(
          sender,
          IMetricOmmSwapQuoter.QuoteHypotheticalExactOutputParams({
            pools: pools,
            extensionDatas: extensionDatas,
            zeroForOneBitMap: 3,
            amountOut: 1500,
            bidPricesX64: bids,
            askPricesX64: asks,
            referencePricesX64: refs
          })
        );
      }
      return quoter.quoteHypotheticalExactInput(
        sender,
        IMetricOmmSwapQuoter.QuoteHypotheticalExactInputParams({
          pools: pools,
          extensionDatas: extensionDatas,
          zeroForOneBitMap: 3,
          amountIn: 2500,
          bidPricesX64: bids,
          askPricesX64: asks,
          referencePricesX64: refs
        })
      );
    }
    if (exactOut) {
      return quoter.quoteLiveExactOut(
        sender,
        IMetricOmmSwapQuoter.QuoteExactOutputParams({
          pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: 1500
        })
      );
    }
    return quoter.quoteLiveExactIn(
      sender,
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2500
      })
    );
  }

  function _deployGatedPool(address token0Addr, address token1Addr) internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) = _getScaleMultipliers(token0Addr, token1Addr);

    PoolExtensions memory extensions;
    extensions.extension1 = address(allowlist);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    deployed = new MetricOmmPool(
      address(factoryStub),
      token0Addr,
      token1Addr,
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
      makeAddr("gatedAdminFeeDest"),
      address(this)
    );
  }
}
