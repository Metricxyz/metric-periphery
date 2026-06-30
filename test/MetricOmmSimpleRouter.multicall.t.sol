// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmSimpleRouterMulticallTest is SimpleRouterTestBase {
  MockERC20Permit internal permitToken;
  MetricOmmPool internal permitPool;

  function setUp() public override {
    super.setUp();
    permitToken = new MockERC20Permit("PermitToken", "PMT", 18);
    permitPool = _deployPool(address(permitToken), address(token1));
    _seedLiquidityPool(permitPool, address(permitToken), address(token1), 10);
    permitToken.mint(swapper, 1_000_000e18);
  }

  function test_multicall_selfPermit_then_exactInputSingle() public {
    uint128 amountIn = 2_000;
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _signPermit(amountIn, deadline);

    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(router.selfPermit.selector, address(permitToken), amountIn, deadline, v, r, s);
    calls[1] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(permitPool),
        tokenIn: address(permitToken),
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
    router.multicall(calls);

    assertGt(token1.balanceOf(recipient), token1Before, "swap succeeded");
    _assertRouterEmpty();
  }

  function test_multicall_selfPermitIfNecessary_skipsWhenAllowanceSufficient() public {
    uint128 amountIn = 1_000;
    uint256 deadline = block.timestamp + 1 hours;

    vm.prank(swapper);
    permitToken.approve(address(router), amountIn);
    uint256 nonceBefore = permitToken.nonces(swapper);

    (uint8 v, bytes32 r, bytes32 s) = _signPermit(amountIn, deadline);

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](1);
    calls[0] =
      abi.encodeWithSelector(router.selfPermitIfNecessary.selector, address(permitToken), amountIn, deadline, v, r, s);
    router.multicall(calls);

    assertEq(permitToken.allowance(swapper, address(router)), amountIn, "allowance unchanged");
    assertEq(permitToken.nonces(swapper), nonceBefore, "permit skipped");
  }

  function test_multicall_selfPermitIfNecessary_permitsWhenInsufficient() public {
    uint128 amountIn = 1_500;
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _signPermit(amountIn, deadline);

    vm.prank(swapper);
    bytes[] memory calls = new bytes[](1);
    calls[0] =
      abi.encodeWithSelector(router.selfPermitIfNecessary.selector, address(permitToken), amountIn, deadline, v, r, s);
    router.multicall(calls);

    assertEq(permitToken.allowance(swapper, address(router)), amountIn, "allowance set");
  }

  function test_multicall_twoSwaps() public {
    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
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
    calls[1] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
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
    bytes[] memory results = router.multicall(calls);

    assertEq(results.length, 2, "two results");
    assertGt(abi.decode(results[0], (uint256)), 0, "first swap out");
    assertGt(abi.decode(results[1], (uint256)), 0, "second swap out");
    _assertRouterEmpty();
  }

  function test_multicall_bubblesRevert() public {
    vm.prank(swapper);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
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
    calls[1] = abi.encodeWithSelector(
      router.exactInputSingle.selector,
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: 100,
        amountOutMinimum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    vm.expectRevert();
    router.multicall(calls);
  }

  function _signPermit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        swapper,
        address(router),
        value,
        permitToken.nonces(swapper),
        deadline
      )
    );
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permitToken.DOMAIN_SEPARATOR(), structHash));
    (v, r, s) = vm.sign(swapperPrivateKey, digest);
  }
}
