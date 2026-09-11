// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmSwapQuoter} from "../contracts/lens/MetricOmmSwapQuoter.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {WrongOutputPoolForSimpleRouter} from "./mocks/RouterPoolMocks.sol";

contract MetricOmmSwapQuoterTest is SimpleRouterTestBase {
  MetricOmmSwapQuoter internal swapQuoter;

  function setUp() public override {
    super.setUp();
    swapQuoter = new MetricOmmSwapQuoter();
  }

  function test_quoteLiveExactInSingle_matchesRouterSwap() public {
    uint128 amountIn = 2_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactInSingle(address(pool), address(0), recipient, true, amountIn, priceLimit, hex"");

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

  function test_quoteLiveExactOutSingle_matchesRouterSwap() public {
    uint128 amountOut = 1_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactOutSingle(address(pool), address(0), recipient, true, amountOut, priceLimit, hex"");

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
      address(0),
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
      address(0),
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

    uint128[] memory refPrices = new uint128[](2);
    refPrices[0] = TEST_BID_X64; // bid≈ask so any in-range ref works; use bid
    refPrices[1] = TEST_BID_X64;

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteHypotheticalExactInput(
      address(0),
      IMetricOmmSwapQuoter.QuoteHypotheticalExactInputParams({
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        bidPricesX64: bidPrices,
        askPricesX64: askPrices,
        referencePricesX64: refPrices
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
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactIn_revertsInvalidInputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(weth), address(token1), address(oracle), 400, -300);

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
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactOut_revertsInvalidOutputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(token1), address(token2), address(oracle), 600, -400);

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
      address(0),
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: 500
      })
    );
  }
}
