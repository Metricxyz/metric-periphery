// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {MetricOmmSwapQuoter} from "../contracts/lens/MetricOmmSwapQuoter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract QuoteSwapResultDecodeProbe {
  function decode(bytes memory reason) external pure returns (int256 amount0Delta, int256 amount1Delta) {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) != MetricOmmSwapQuoter.QuoteSwapResult.selector) revert("unexpected selector");
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
      swapQuoter.quoteSwapExactIn(address(pool), recipient, true, amountIn, priceLimit, hex"");

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    vm.prank(swapper);
    uint256 actualOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: priceLimit,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteSwapExactOut_decodesCallbackRevert() public {
    uint128 amountOut = 1_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteSwapExactOut(address(pool), recipient, true, amountOut, priceLimit, hex"");

    assertEq(quotedOut, amountOut, "quoted amountOut");
    assertGt(quotedIn, 0, "quoted amountIn");

    vm.prank(swapper);
    uint256 actualIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountOut: amountOut,
        amountInMaximum: type(uint128).max,
        priceLimitX64: priceLimit,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertEq(quotedIn, actualIn, "quote matches swap");
  }
}
