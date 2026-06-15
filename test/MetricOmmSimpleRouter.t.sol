// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {
  MaliciousPoolForSimpleRouter,
  ReentrantPoolForSimpleRouter,
  WrongOutputPoolForSimpleRouter
} from "./mocks/RouterPoolMocks.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmSimpleRouterTest is SimpleRouterTestBase {
  // ============ Single-hop happy paths ============

  function test_exactInputSingle_zeroForOne() public {
    uint128 amountIn = 2_500;
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 wethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "recipient token1");
    assertEq(wethBefore - weth.balanceOf(swapper), amountIn, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_exactInputSingle_oneForZero() public {
    uint128 amountIn = 2_500;
    uint256 wethBefore = weth.balanceOf(recipient);
    uint256 token1Before = token1.balanceOf(swapper);

    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: false,
        tokenIn: address(token1),
        tokenOut: address(weth),
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(weth.balanceOf(recipient) - wethBefore, amountOut, "recipient weth");
    assertEq(token1Before - token1.balanceOf(swapper), amountIn, "swapper token1 spent");
    _assertRouterEmpty();
  }

  function test_exactOutputSingle_zeroForOne() public {
    uint128 amountOut = 1_500;
    uint256 wethBefore = weth.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountOut: amountOut,
        amountInMaximum: 10_000,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertGt(amountIn, 0, "amountIn > 0");
    assertLe(amountIn, 10_000, "amountIn <= max");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "exact token1 out");
    assertEq(wethBefore - weth.balanceOf(swapper), amountIn, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_exactOutputSingle_oneForZero() public {
    uint128 amountOut = 1_500;
    uint256 token1Before = token1.balanceOf(swapper);
    uint256 wethBefore = weth.balanceOf(recipient);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: false,
        tokenIn: address(token1),
        tokenOut: address(weth),
        amountOut: amountOut,
        amountInMaximum: 10_000,
        priceLimitX64: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertGt(amountIn, 0, "amountIn > 0");
    assertEq(weth.balanceOf(recipient) - wethBefore, amountOut, "exact weth out");
    assertEq(token1Before - token1.balanceOf(swapper), amountIn, "swapper token1 spent");
    _assertRouterEmpty();
  }

  function test_exactInputSingle_recipientIsThirdParty() public {
    uint128 amountIn = 1_000;
    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertGt(token1.balanceOf(recipient), token1Before, "recipient received output");
    assertEq(token1.balanceOf(swapper), 1_000_000e18, "swapper token1 unchanged");
  }

  // ============ Multihop happy paths ============

  function test_exactInput_twoHop() public {
    uint128 amountIn = 2_000;
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

    uint256 token2Before = token2.balanceOf(recipient);
    uint256 wethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    uint256 amountOut = router.exactInput(
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

    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(token2.balanceOf(recipient) - token2Before, amountOut, "recipient token2");
    assertEq(wethBefore - weth.balanceOf(swapper), amountIn, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_exactInput_threeHop() public {
    MockERC20 token3 = new MockERC20("Token3", "TK3", 18);
    MetricOmmPool pool23 = _deployPool(address(token2), address(token3));
    _seedLiquidityPool(pool23, address(token2), address(token3), 2);
    token3.mint(swapper, 1_000_000e18);
    vm.prank(swapper);
    token3.approve(address(router), type(uint256).max);

    address[] memory tokens = new address[](4);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
    tokens[3] = address(token3);

    address[] memory pools = new address[](3);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    pools[2] = address(pool23);

    bytes[] memory extensionDatas = new bytes[](3);

    uint128 amountIn = 1_500;
    uint256 token3Before = token3.balanceOf(recipient);

    vm.prank(swapper);
    uint256 amountOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 7,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(token3.balanceOf(recipient) - token3Before, amountOut, "recipient token3");
    assertEq(token3.balanceOf(address(router)), 0, "router token3");
  }

  function test_exactOutput_twoHop() public {
    uint128 amountOut = 1_000;

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    uint256 wethBefore = weth.balanceOf(swapper);
    uint256 token2Before = token2.balanceOf(recipient);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutput(
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

    assertGt(amountIn, 0, "amountIn > 0");
    assertLe(amountIn, 10_000, "amountIn <= max");
    assertEq(token2.balanceOf(recipient) - token2Before, amountOut, "exact token2 out");
    assertEq(wethBefore - weth.balanceOf(swapper), amountIn, "swapper weth spent");
    _assertRouterEmpty();
  }

  function test_exactOutput_threeHop() public {
    MockERC20 token3 = new MockERC20("Token3", "TK3", 18);
    MetricOmmPool pool23 = _deployPool(address(token2), address(token3));
    _seedLiquidityPool(pool23, address(token2), address(token3), 2);
    token3.mint(swapper, 1_000_000e18);
    vm.prank(swapper);
    token3.approve(address(router), type(uint256).max);

    uint128 amountOut = 800;

    address[] memory tokens = new address[](4);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
    tokens[3] = address(token3);

    address[] memory pools = new address[](3);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    pools[2] = address(pool23);

    bytes[] memory extensionDatas = new bytes[](3);

    uint256 wethBefore = weth.balanceOf(swapper);
    uint256 token3Before = token3.balanceOf(recipient);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 7,
        amountOut: amountOut,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertGt(amountIn, 0, "amountIn > 0");
    assertEq(token3.balanceOf(recipient) - token3Before, amountOut, "exact token3 out");
    assertEq(wethBefore - weth.balanceOf(swapper), amountIn, "swapper weth spent");
    assertEq(token3.balanceOf(address(router)), 0, "router token3");
  }

  // ============ Slippage & deadline ============

  function test_exactInputSingle_revertsAmountTooLarge() public {
    uint128 amountIn = MAX_INT128_AS_UINT128 + 1;

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.AmountTooLarge.selector, amountIn));
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }

  function test_exactOutputSingle_revertsAmountTooLarge() public {
    uint128 amountOut = MAX_INT128_AS_UINT128 + 1;

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.AmountTooLarge.selector, amountOut));
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: type(uint128).max,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }

  function test_exactInputSingle_revertsInsufficientOutput() public {
    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 100,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmSimpleRouter.InsufficientOutput.selector, amountOut, amountOut + 1)
    );
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 100,
        amountOutMinimum: uint128(amountOut + 1),
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }

  function test_exactOutputSingle_revertsInputTooHigh() public {
    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountOut: 100,
        amountInMaximum: type(uint128).max,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InputTooHigh.selector, amountIn, amountIn - 1));
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountOut: 100,
        amountInMaximum: uint128(amountIn - 1),
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }

  function test_exactInput_revertsInsufficientOutput() public {
    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    uint256 amountOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmSimpleRouter.InsufficientOutput.selector, amountOut, amountOut + 1)
    );
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: 100,
        amountOutMinimum: uint128(amountOut + 1),
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactOutput_revertsInputTooHigh() public {
    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: 100,
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InputTooHigh.selector, amountIn, amountIn - 1));
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: 100,
        amountInMaximum: uint128(amountIn - 1),
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactInputSingle_revertsTransactionExpired() public {
    uint256 deadline = 100;
    vm.warp(101);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.TransactionExpired.selector, deadline, uint256(101)));
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 100,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: deadline,
        extensionData: ""
      })
    );
  }

  function test_exactInput_revertsTransactionExpired() public {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    address[] memory pools = new address[](1);
    pools[0] = address(pool);
    bytes[] memory extensionDatas = new bytes[](1);

    uint256 deadline = 200;
    vm.warp(201);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.TransactionExpired.selector, deadline, uint256(201)));
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: deadline
      })
    );
  }

  function test_exactOutputSingle_revertsTransactionExpired() public {
    uint256 deadline = 300;
    vm.warp(301);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.TransactionExpired.selector, deadline, uint256(301)));
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountOut: 100,
        amountInMaximum: 10_000,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: deadline,
        extensionData: ""
      })
    );
  }

  function test_exactOutput_revertsTransactionExpired() public {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    address[] memory pools = new address[](1);
    pools[0] = address(pool);
    bytes[] memory extensionDatas = new bytes[](1);

    uint256 deadline = 400;
    vm.warp(401);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.TransactionExpired.selector, deadline, uint256(401)));
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountOut: 100,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: deadline
      })
    );
  }

  // ============ Path validation ============

  function test_exactInput_revertsInvalidPath_tooFewTokens() public {
    address[] memory tokens = new address[](1);
    tokens[0] = address(weth);
    address[] memory pools = new address[](1);
    pools[0] = address(pool);
    bytes[] memory extensionDatas = new bytes[](1);

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidPath.selector);
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactInput_revertsInvalidPath_poolTokenMismatch() public {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidPath.selector);
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactInput_revertsInvalidPath_extensionDataMismatch() public {
    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);
    bytes[] memory extensionDatas = new bytes[](1);

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidPath.selector);
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactOutput_revertsInvalidPath() public {
    address[] memory tokens = new address[](1);
    tokens[0] = address(weth);
    address[] memory pools = new address[](1);
    pools[0] = address(pool);
    bytes[] memory extensionDatas = new bytes[](1);

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidPath.selector);
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountOut: 100,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  // ============ Callback security ============

  function test_callback_revertsInvalidCallbackCaller_directCall() public {
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidCallbackCaller.selector);
    router.metricOmmSwapCallback(100, -100, "");
  }

  function test_callback_revertsInvalidSwapDeltas() public {
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidSwapDeltas.selector);
    router.metricOmmSwapCallback(0, 0, "");
  }

  function test_cannotDrainThirdPartyApprovals() public {
    address victim = makeAddr("victim");
    token1.mint(victim, 1_000_000e18);
    vm.prank(victim);
    token1.approve(address(router), type(uint256).max);

    uint256 victimBefore = token1.balanceOf(victim);

    MaliciousPoolForSimpleRouter malicious = new MaliciousPoolForSimpleRouter(address(weth), address(token1), -1, 1000);

    uint256 poolBefore = token1.balanceOf(address(malicious));

    vm.prank(swapper);
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(malicious),
        zeroForOne: false,
        tokenIn: address(token1),
        tokenOut: address(weth),
        amountIn: 1000,
        amountOutMinimum: 0,
        priceLimitX64: type(uint128).max,
        recipient: swapper,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertEq(token1.balanceOf(victim), victimBefore, "victim unchanged");
    assertEq(token1.balanceOf(address(malicious)) - poolBefore, 1000, "pool received from swapper");
  }

  function test_reentrantPool_nestedCallbackAttempt() public {
    ReentrantPoolForSimpleRouter reentrant = new ReentrantPoolForSimpleRouter(address(weth), address(token1), 1000, -1);

    vm.prank(swapper);
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(reentrant),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 1000,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertTrue(reentrant.nestedAttempted(), "nested attempted");
  }

  function test_twoSequentialSwapsSameTx() public {
    vm.startPrank(swapper);
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 500,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 500,
        amountOutMinimum: 0,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
    vm.stopPrank();
    _assertRouterEmpty();
  }

  function test_exactOutputSingle_revertsInvalidOutputAmount() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(weth), address(token1), 600, -400);

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidOutputAmount.selector, int128(400), uint128(500))
    );
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(wrongPool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: 500,
        amountInMaximum: 10_000,
        priceLimitX64: 0,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }

  function test_exactOutput_revertsInvalidOutputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(weth), address(token1), 500, -400);

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    address[] memory pools = new address[](2);
    pools[0] = address(wrongPool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.InvalidOutputAmountAtHop.selector, uint8(0), int128(400), int256(501)
      )
    );
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: 500,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  // ============ Fuzz ============

  function testFuzz_exactInputSingle_matchesQuote(uint96 rawAmount, bool zeroForOne) public {
    uint128 amountIn = uint128(bound(uint256(rawAmount), 1, 100_000));
    uint128 priceLimit = _priceLimit(zeroForOne);

    (int128 q0, int128 q1) = quoter.quoteSwap(
      address(pool), zeroForOne, int128(int256(uint256(amountIn))), priceLimit, uint128(Q64), uint128(Q64)
    );
    int128 quotedOut = zeroForOne ? -q1 : -q0;
    vm.assume(quotedOut > 0);

    address tokenIn = zeroForOne ? address(weth) : address(token1);
    address tokenOut = zeroForOne ? address(token1) : address(weth);

    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: zeroForOne,
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: amountIn,
        amountOutMinimum: 0,
        priceLimitX64: priceLimit,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertEq(amountOut, uint256(int256(quotedOut)), "output matches quote");
    _assertRouterEmpty();
  }

  function testFuzz_exactOutputSingle_amountInWithinMax(uint96 rawAmount, bool zeroForOne) public {
    uint128 amountOut = uint128(bound(uint256(rawAmount), 1, 50_000));
    uint128 priceLimit = _priceLimit(zeroForOne);

    (int128 q0, int128 q1) = quoter.quoteSwap(
      address(pool), zeroForOne, -int128(int256(uint256(amountOut))), priceLimit, uint128(Q64), uint128(Q64)
    );
    int128 quotedIn = zeroForOne ? q0 : q1;
    vm.assume(quotedIn > 0);

    address tokenIn = zeroForOne ? address(weth) : address(token1);
    address tokenOut = zeroForOne ? address(token1) : address(weth);
    uint128 maxIn = uint128(uint256(int256(quotedIn)) * 2 + 1);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        zeroForOne: zeroForOne,
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountOut: amountOut,
        amountInMaximum: maxIn,
        priceLimitX64: priceLimit,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );

    assertLe(amountIn, maxIn, "amountIn <= max");
    assertEq(amountIn, uint256(int256(quotedIn)), "amountIn matches quote");
    _assertRouterEmpty();
  }

  function test_exactInputSingle_revertsInvalidPriceLimitForDirection() public {
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPriceLimitForDirection.selector, true, type(uint128).max)
    );
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        zeroForOne: true,
        tokenIn: address(weth),
        tokenOut: address(token1),
        amountIn: 100,
        amountOutMinimum: 0,
        priceLimitX64: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        extensionData: ""
      })
    );
  }
}
