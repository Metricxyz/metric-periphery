// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {MaliciousPoolForSimpleRouter} from "./mocks/RouterPoolMocks.sol";
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
        tokenIn: address(token1),
        tokenOut: address(weth),
        zeroForOne: false,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: type(uint128).max,
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
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
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
        tokenIn: address(token1),
        tokenOut: address(weth),
        zeroForOne: false,
        amountOut: amountOut,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: type(uint128).max,
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
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
  }

  function test_exactInputSingle_revertsInsufficientOutput() public {
    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
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
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 100,
        amountOutMinimum: uint128(amountOut + 1),
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
  }

  function test_exactOutputSingle_revertsInputTooHigh() public {
    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: 100,
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InputTooHigh.selector, amountIn, amountIn - 1));
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: 100,
        amountInMaximum: uint128(amountIn - 1),
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
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
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: deadline,
        priceLimitX64: 0,
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
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: 100,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: deadline,
        priceLimitX64: 0,
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

  function test_exactInputSingle_revertsInvalidPool() public {
    MaliciousPoolForSimpleRouter malicious = new MaliciousPoolForSimpleRouter(address(weth), address(token1), -1, 1000);

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, address(malicious)));
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(malicious),
        tokenIn: address(token1),
        tokenOut: address(weth),
        zeroForOne: false,
        amountIn: 1000,
        amountOutMinimum: 0,
        recipient: swapper,
        deadline: _deadline(),
        priceLimitX64: type(uint128).max,
        extensionData: ""
      })
    );
  }

  function test_exactOutputSingle_revertsInvalidPool() public {
    MaliciousPoolForSimpleRouter malicious = new MaliciousPoolForSimpleRouter(address(weth), address(token1), 1000, -1);

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, address(malicious)));
    router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(malicious),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: 1000,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
  }

  function test_exactInput_revertsInvalidPool() public {
    MaliciousPoolForSimpleRouter malicious =
      new MaliciousPoolForSimpleRouter(address(token1), address(token2), -1, 1000);

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(malicious);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, address(malicious)));
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: 2_000,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_exactOutput_revertsInvalidPool() public {
    MaliciousPoolForSimpleRouter malicious = new MaliciousPoolForSimpleRouter(address(weth), address(token1), 1000, -1);

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    address[] memory pools = new address[](2);
    pools[0] = address(malicious);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, address(malicious)));
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: 1_000,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function test_twoSequentialSwapsSameTx() public {
    vm.startPrank(swapper);
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 500,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
    router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 500,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
    vm.stopPrank();
    _assertRouterEmpty();
  }

  // ============ Fuzz ============

  function testFuzz_exactInputSingle_matchesQuote(uint96 rawAmount, bool zeroForOne) public {
    uint128 amountIn = uint128(bound(uint256(rawAmount), 1, 100_000));
    uint128 priceLimit = _priceLimit(zeroForOne);

    try quoter.quoteHypotheticalExactInputSingle(
      address(pool), zeroForOne, amountIn, priceLimit, TEST_BID_X64, TEST_ASK_X64
    ) returns (
      uint256 quotedIn, uint256 quotedOut
    ) {
      vm.assume(quotedOut > 0);
      assertEq(quotedIn, amountIn, "quoted amountIn");

      address tokenIn = zeroForOne ? address(weth) : address(token1);
      address tokenOut = zeroForOne ? address(token1) : address(weth);

      vm.prank(swapper);
      uint256 amountOut = router.exactInputSingle(
        IMetricOmmSimpleRouter.ExactInputSingleParams({
          pool: address(pool),
          tokenIn: tokenIn,
          tokenOut: tokenOut,
          zeroForOne: zeroForOne,
          amountIn: amountIn,
          amountOutMinimum: 0,
          recipient: recipient,
          deadline: _deadline(),
          priceLimitX64: priceLimit,
          extensionData: ""
        })
      );

      assertEq(amountOut, quotedOut, "output matches quote");
      _assertRouterEmpty();
    } catch {
      vm.assume(false);
    }
  }

  function testFuzz_exactOutputSingle_amountInWithinMax(uint96 rawAmount, bool zeroForOne) public {
    uint128 amountOut = uint128(bound(uint256(rawAmount), 1, 50_000));
    uint128 priceLimit = _priceLimit(zeroForOne);

    try quoter.quoteHypotheticalExactOutputSingle(
      address(pool), zeroForOne, amountOut, priceLimit, TEST_BID_X64, TEST_ASK_X64
    ) returns (
      uint256 quotedIn, uint256 quotedOut
    ) {
      vm.assume(quotedIn > 0);
      assertEq(quotedOut, amountOut, "quoted amountOut");

      address tokenIn = zeroForOne ? address(weth) : address(token1);
      address tokenOut = zeroForOne ? address(token1) : address(weth);
      uint128 maxIn = uint128(quotedIn * 2 + 1);

      vm.prank(swapper);
      uint256 amountIn = router.exactOutputSingle(
        IMetricOmmSimpleRouter.ExactOutputSingleParams({
          pool: address(pool),
          tokenIn: tokenIn,
          tokenOut: tokenOut,
          zeroForOne: zeroForOne,
          amountOut: amountOut,
          amountInMaximum: maxIn,
          recipient: recipient,
          deadline: _deadline(),
          priceLimitX64: priceLimit,
          extensionData: ""
        })
      );

      assertLe(amountIn, maxIn, "amountIn <= max");
      assertEq(amountIn, quotedIn, "amountIn matches quote");
      _assertRouterEmpty();
    } catch {
      vm.assume(false);
    }
  }

  function test_exactInputSingle_normalizesOpenPriceLimitSentinel() public {
    vm.prank(swapper);
    uint256 amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: type(uint128).max,
        extensionData: ""
      })
    );
    assertGt(amountOut, 0);

    vm.prank(swapper);
    amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(token1),
        tokenOut: address(weth),
        zeroForOne: false,
        amountIn: 100,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );
    assertGt(amountOut, 0);
  }
}
