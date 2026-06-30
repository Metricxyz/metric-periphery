// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {PeripheryPayments} from "../contracts/base/PeripheryPayments.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmSimpleRouterPaymentsTest is SimpleRouterTestBase {
  function test_constructor_revertsOnZeroWeth() public {
    vm.expectRevert(PeripheryPayments.InvalidWETH.selector);
    new MetricOmmSimpleRouter(address(0), address(factoryStub));
  }

  function test_constructor_revertsOnZeroFactory() public {
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidFactory.selector);
    new MetricOmmSimpleRouter(address(weth), address(0));
  }

  function test_receive_acceptsWethWithdraw() public {
    vm.deal(address(weth), 1 ether);
    vm.prank(address(weth));
    (bool ok,) = address(router).call{value: 1 ether}("");
    assertTrue(ok, "weth withdraw accepted");
    assertEq(address(router).balance, 1 ether, "router eth");
  }

  function test_receive_revertsOnDirectEthTransfer() public {
    vm.deal(swapper, 1 ether);
    vm.prank(swapper);
    vm.expectRevert(PeripheryPayments.NotWETH.selector);
    (bool ok,) = address(router).call{value: 1 ether}("");
    ok;
  }

  function test_unwrapWETH9_sendsEthToRecipient() public {
    uint256 amount = 1 ether;
    weth.deposit{value: amount}();
    weth.transfer(address(router), amount);

    uint256 recipientBefore = recipient.balance;

    router.unwrapWETH9(amount, recipient);

    assertEq(weth.balanceOf(address(router)), 0, "router weth cleared");
    assertEq(recipient.balance - recipientBefore, amount, "recipient eth");
    assertEq(address(router).balance, 0, "router eth cleared");
  }

  function test_unwrapWETH9_revertsWhenBalanceTooLow() public {
    vm.expectRevert(abi.encodeWithSelector(PeripheryPayments.InsufficientWETH.selector, 1 ether, 0));
    router.unwrapWETH9(1 ether, recipient);
  }

  function test_sweepToken_sendsFullBalance() public {
    uint256 amount = 123_456;
    token1.mint(address(router), amount);

    uint256 recipientBefore = token1.balanceOf(recipient);

    router.sweepToken(address(token1), amount, recipient);

    assertEq(token1.balanceOf(address(router)), 0, "router token cleared");
    assertEq(token1.balanceOf(recipient) - recipientBefore, amount, "recipient token");
  }

  function test_sweepToken_revertsWhenBalanceTooLow() public {
    vm.expectRevert(abi.encodeWithSelector(PeripheryPayments.InsufficientToken.selector, address(token1), 1, 0));
    router.sweepToken(address(token1), 1, recipient);
  }

  function test_refundETH_sendsBalanceToCaller() public {
    uint256 amount = 2 ether;
    vm.deal(address(router), amount);

    uint256 swapperBefore = swapper.balance;

    vm.prank(swapper);
    router.refundETH();

    assertEq(swapper.balance - swapperBefore, amount, "swapper refunded");
    assertEq(address(router).balance, 0, "router eth cleared");
  }
}
