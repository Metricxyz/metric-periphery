// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {MetricOmmSwapQuoter} from "../contracts/lens/MetricOmmSwapQuoter.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {WrongOutputPoolForSimpleRouter} from "./mocks/RouterPoolMocks.sol";

contract QuoteSwapResultDecodeProbe {
  function decode(bytes memory reason) external pure returns (int256 amount0Delta, int256 amount1Delta) {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) != IMetricOmmSwapQuoter.QuoteSwapResult.selector) revert("unexpected selector");
    assembly ("memory-safe") {
      amount0Delta := mload(add(reason, 36))
      amount1Delta := mload(add(reason, 68))
    }
  }
}

contract QuoteSwapCallbackTrigger {
  function trigger(address quoter, int256 amount0Delta, int256 amount1Delta) external {
    IMetricOmmSwapCallback(quoter).metricOmmSwapCallback(amount0Delta, amount1Delta, hex"");
  }
}

contract MetricOmmSwapQuoterTest is SimpleRouterTestBase {
  MetricOmmSwapQuoter internal swapQuoter;
  QuoteSwapResultDecodeProbe internal decodeProbe;
  QuoteSwapCallbackTrigger internal callbackTrigger;

  function setUp() public override {
    super.setUp();
    swapQuoter = new MetricOmmSwapQuoter();
    decodeProbe = new QuoteSwapResultDecodeProbe();
    callbackTrigger = new QuoteSwapCallbackTrigger();
  }

  function test_decodeQuoteSwapResult_fromCallbackRevert() public {
    int256 expectedAmount0Delta = 2_500;
    int256 expectedAmount1Delta = -2_400;

    try callbackTrigger.trigger(address(swapQuoter), expectedAmount0Delta, expectedAmount1Delta) {
      fail("callback should revert with QuoteSwapResult");
    } catch (bytes memory reason) {
      (int256 amount0Delta, int256 amount1Delta) = decodeProbe.decode(reason);
      assertEq(amount0Delta, expectedAmount0Delta, "amount0Delta");
      assertEq(amount1Delta, expectedAmount1Delta, "amount1Delta");
    }
  }

  function test_quoteSwapExactIn_decodesCallbackRevert() public {
    uint128 amountIn = 2_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactInSingle(address(pool), recipient, true, amountIn, priceLimit, hex"");

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    vm.prank(swapper);
    uint256 actualOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: priceLimit,
        extensionData: ""
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteSwapExactOut_decodesCallbackRevert() public {
    uint128 amountOut = 1_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactOutSingle(address(pool), recipient, true, amountOut, priceLimit, hex"");

    assertEq(quotedOut, amountOut, "quoted amountOut");
    assertGt(quotedIn, 0, "quoted amountIn");

    vm.prank(swapper);
    uint256 actualIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: priceLimit,
        extensionData: ""
      })
    );

    assertEq(quotedIn, actualIn, "quote matches swap");
  }

  function test_quoteLiveExactIn_twoHop_matchesRouter() public {
    uint128 amountIn = 2_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteLiveExactIn(
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: amountIn
      })
    );

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteLiveExactOut_twoHop_matchesRouter() public {
    uint128 amountOut = 1_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteLiveExactOut(
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: amountOut
      })
    );

    assertEq(quotedOut, amountOut, "quoted amountOut");
    assertGt(quotedIn, 0, "quoted amountIn");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualIn = router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: amountOut,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedIn, actualIn, "quote matches swap");
  }

  function test_quoteHypotheticalExactInput_twoHop_matchesRouter() public {
    uint128 amountIn = 2_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    uint128[] memory bidPrices = new uint128[](2);
    bidPrices[0] = TEST_BID_X64;
    bidPrices[1] = TEST_BID_X64;

    uint128[] memory askPrices = new uint128[](2);
    askPrices[0] = TEST_ASK_X64;
    askPrices[1] = TEST_ASK_X64;

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteHypotheticalExactInput(
      IMetricOmmSwapQuoter.QuoteHypotheticalExactInputParams({
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        bidPricesX64: bidPrices,
        askPricesX64: askPrices
      })
    );

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteLiveExactIn_revertsInvalidPath_disconnectedPools() public {
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(IMetricOmmSwapQuoter.InvalidPath.selector);
    swapQuoter.quoteLiveExactIn(
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactIn_revertsInvalidInputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(weth), address(token1), 400, -300);

    address[] memory pools = new address[](2);
    pools[0] = address(wrongPool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.InvalidInputAmountAtHop.selector, uint8(0), uint256(400), uint256(2000)
      )
    );
    swapQuoter.quoteLiveExactIn(
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactOut_revertsInvalidOutputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(token1), address(token2), 600, -400);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(wrongPool);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.InvalidOutputAmountAtHop.selector, uint8(1), uint256(400), uint256(500)
      )
    );
    swapQuoter.quoteLiveExactOut(
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: 500
      })
    );
  }
}
