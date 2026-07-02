// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

/// @dev Native ETH flows follow Uniswap v3-periphery multicall patterns:
///      - ETH input: multicall{value}(exactInput*) with WETH as tokenIn
///      - ETH output: swap WETH to router, then unwrapWETH9 in the same multicall
contract MetricOmmSimpleRouterNativeTest is SimpleRouterTestBase {
  function test_multicall_ethInput_exactInputSingle_wethForToken() public {
    uint128 amountIn = 2_500;
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 swapperEthBefore = swapper.balance;

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
    router.multicall{value: amountIn}(calls);

    assertGt(token1.balanceOf(recipient) - token1Before, 0, "recipient token1");
    assertEq(swapperEthBefore - swapper.balance, amountIn, "swapper eth spent");
    _assertRouterEmpty();
  }

  function test_mixedNativeAndWeth_exactInputSingle_wethForToken() public {
    uint128 amountIn = 2_500;
    uint256 nativePart = amountIn / 2;
    uint256 wethPart = amountIn - nativePart;

    uint256 token1Before = token1.balanceOf(recipient);
    uint256 swapperEthBefore = swapper.balance;
    uint256 swapperWethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    router.exactInputSingle{value: nativePart}(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    assertGt(token1.balanceOf(recipient) - token1Before, 0, "recipient token1");
    assertEq(swapperEthBefore - swapper.balance, nativePart, "swapper native spent");
    assertEq(swapperWethBefore - weth.balanceOf(swapper), wethPart, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_mixedNativeAndWeth_exactOutputSingle_wethForToken() public {
    uint128 amountOut = 1_500;
    (uint256 quotedIn,) =
      quoter.quoteHypotheticalExactOutputSingle(address(pool), true, amountOut, 0, TEST_BID_X64, TEST_ASK_X64);
    uint256 nativePart = quotedIn / 2;
    uint256 wethPart = quotedIn - nativePart;

    uint256 token1Before = token1.balanceOf(recipient);
    uint256 swapperEthBefore = swapper.balance;
    uint256 swapperWethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle{value: nativePart}(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: uint128(quotedIn * 2 + 1),
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    assertEq(amountIn, quotedIn, "amountIn matches quote");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "exact token1 out");
    assertEq(swapperEthBefore - swapper.balance, nativePart, "swapper native spent");
    assertEq(swapperWethBefore - weth.balanceOf(swapper), wethPart, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_multicall_ethInput_exactInputSingle_refundsUnusedEth() public {
    uint128 amountIn = 1_000;
    uint256 msgValue = 2 ether;
    uint256 swapperEthBefore = swapper.balance;

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
    calls[1] = abi.encodeWithSelector(router.refundETH.selector);
    router.multicall{value: msgValue}(calls);

    assertEq(swapper.balance, swapperEthBefore - amountIn, "unused eth refunded");
    _assertRouterEmpty();
  }

  function test_multicall_tokenForWeth_thenUnwrapEth() public {
    uint128 amountIn = 3_000;
    uint256 recipientEthBefore = recipient.balance;

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(token1),
        tokenOut: address(weth),
        zeroForOne: false,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: address(router),
        deadline: _deadline(),
        priceLimitX64: type(uint128).max,
        extensionData: ""
      })
    );
    calls[1] = abi.encodeWithSelector(router.unwrapWETH9.selector, uint256(0), recipient);
    router.multicall(calls);

    assertGt(recipient.balance, recipientEthBefore, "recipient received eth");
    assertEq(weth.balanceOf(address(router)), 0, "router weth cleared");
    assertEq(address(router).balance, 0, "router eth cleared");
  }

  function test_multicall_ethInput_multihop_wethToToken2() public {
    uint128 amountIn = 5_000;
    uint256 token2Before = token2.balanceOf(recipient);

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);
    extensionDatas[0] = "";
    extensionDatas[1] = "";

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSelector(
      router.exactInput.selector,
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
    router.multicall{value: amountIn}(calls);

    assertGt(token2.balanceOf(recipient) - token2Before, 0, "recipient token2");
    _assertRouterEmpty();
  }

  function test_multicall_multihop_tokenToWeth_thenUnwrapEth() public {
    uint128 amountIn = 4_000;
    uint256 recipientEthBefore = recipient.balance;

    address[] memory tokens = new address[](3);
    tokens[0] = address(token2);
    tokens[1] = address(token1);
    tokens[2] = address(weth);

    address[] memory pools = new address[](2);
    pools[0] = address(pool12);
    pools[1] = address(pool);

    bytes[] memory extensionDatas = new bytes[](2);
    extensionDatas[0] = "";
    extensionDatas[1] = "";

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      router.exactInput.selector,
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 0,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: address(router),
        deadline: _deadline()
      })
    );
    calls[1] = abi.encodeWithSelector(router.unwrapWETH9.selector, uint256(0), recipient);
    router.multicall(calls);

    assertGt(recipient.balance, recipientEthBefore, "recipient received eth");
    _assertRouterEmpty();
  }
}
