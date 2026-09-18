// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract MisreportingExecutor {
  function swap(IExternalSwap.ExternalSwapParams calldata params) external returns (uint256 amountSpent) {
    uint256 output;
    uint256 refund;
    (amountSpent, output, refund) = abi.decode(params.externalRouterCalldata, (uint256, uint256, uint256));
    if (refund > 0) IERC20(params.tokenIn).transfer(msg.sender, refund);
    if (output > 0) IERC20(params.tokenOut).transfer(params.recipient, output);
  }
}

contract BalanceDrainingExecutor {
  function swap(IExternalSwap.ExternalSwapParams calldata params) external {
    IERC20(params.tokenIn).transferFrom(msg.sender, address(this), 1 ether);
  }
}

contract ExternalSettlementTest is Test {
  MetricOmmSimpleRouter router;
  MisreportingExecutor executor;
  MockERC20Permit input;
  MockERC20Permit output;
  address recipient = address(this);

  function setUp() public {
    router = new MetricOmmSimpleRouter(address(1), address(2));
    executor = new MisreportingExecutor();
    input = new MockERC20Permit("Input", "IN", 18);
    output = new MockERC20Permit("Output", "OUT", 18);
    input.mint(address(this), 100 ether);
    output.mint(address(executor), 100 ether);
    input.approve(address(router), 100 ether);
  }

  function _params(uint256 reportedSpent, uint256 deliveredOutput, uint256 refund)
    private
    view
    returns (IExternalSwap.ExternalSwapParams memory)
  {
    return IExternalSwap.ExternalSwapParams(
      address(input),
      address(output),
      10 ether,
      5 ether,
      address(output),
      abi.encode(reportedSpent, deliveredOutput, refund),
      recipient,
      type(uint256).max
    );
  }

  function test_externalSwap_measuresSpentWhenExecutorUnderreports() public {
    (uint256 amountOut, uint256 spent) =
      router.externalSwap(address(executor), false, false, _params(0, 5 ether, 2 ether));
    assertEq(amountOut, 5 ether);
    assertEq(spent, 8 ether);
    assertEq(input.balanceOf(address(router)), 0);
    assertEq(output.balanceOf(recipient), 5 ether);
  }

  function test_externalSwap_existingRouterBalanceDoesNotCountAsRefund() public {
    input.mint(address(router), 10 ether);
    (, uint256 spent) = router.externalSwap(address(executor), false, false, _params(0, 5 ether, 2 ether));
    assertEq(spent, 8 ether);
    assertEq(input.balanceOf(address(router)), 10 ether);
  }

  function test_externalSwap_revertsWhenExecutorConsumesExistingRouterInput() public {
    BalanceDrainingExecutor drainingExecutor = new BalanceDrainingExecutor();
    input.mint(address(router), 2 ether);
    vm.prank(address(router));
    input.approve(address(drainingExecutor), 1 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        IExternalSwap.ExternalSwapBalanceMismatch.selector, address(input), address(router), 2 ether, 1 ether
      )
    );
    router.externalSwap(address(drainingExecutor), false, false, _params(0, 0, 0));
    assertEq(input.balanceOf(address(router)), 2 ether);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_verifiesOutputWhenRecipientIsRouter() public {
    output.mint(address(router), 10 ether);
    IExternalSwap.ExternalSwapParams memory params = _params(7 ether, 4 ether, 3 ether);
    params.recipient = address(router);
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 4 ether, 5 ether));
    router.externalSwap(address(executor), false, false, params);
    assertEq(output.balanceOf(address(router)), 10 ether);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_revertsOnInsufficientDeliveredOutput() public {
    IExternalSwap.ExternalSwapParams memory params = _params(7 ether, 4 ether, 3 ether);
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 4 ether, 5 ether));
    router.externalSwap(address(executor), false, false, params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_ignoresOverreportedSpend() public {
    (, uint256 spent) =
      router.externalSwap(address(executor), false, false, _params(type(uint256).max, 5 ether, 3 ether));
    assertEq(spent, 7 ether);
  }

  function test_externalSwap_missingRefundCountsAsFullSpend() public {
    (, uint256 spent) = router.externalSwap(address(executor), false, false, _params(0, 5 ether, 0));
    assertEq(spent, 10 ether);
    assertEq(input.balanceOf(address(router)), 0);
  }

  function test_externalSwap_reportsDeliveredOutputExcludingExistingBalance() public {
    output.mint(recipient, 3 ether);
    (uint256 amountOut, uint256 spent) =
      router.externalSwap(address(executor), false, false, _params(7 ether, 6 ether, 3 ether));
    assertEq(amountOut, 6 ether);
    assertEq(spent, 7 ether);
    assertEq(output.balanceOf(recipient), 9 ether);
  }

  function test_externalSwap_acceptsExtraRefund() public {
    (uint256 amountOut, uint256 spent) =
      router.externalSwap(address(executor), false, false, _params(7 ether, 5 ether, 4 ether));
    assertEq(amountOut, 5 ether);
    assertEq(spent, 6 ether);
    assertEq(input.balanceOf(address(this)), 94 ether);
    assertEq(input.balanceOf(address(router)), 0);
  }

  function testFuzz_externalSwap_measuresNetSpendDespiteExecutorReturn(uint256 reportedSpent, uint96 refund) public {
    uint256 refunded = bound(uint256(refund), 0, 20 ether);
    input.mint(address(executor), 10 ether);
    (, uint256 spent) = router.externalSwap(address(executor), false, false, _params(reportedSpent, 5 ether, refunded));
    assertLe(spent, 10 ether);
    assertEq(input.balanceOf(address(router)), 0);
    assertEq(input.balanceOf(address(this)), 90 ether + refunded);
    if (refunded <= 10 ether) {
      assertEq(spent + refunded, 10 ether);
    } else {
      assertEq(spent, 0);
    }
  }
}
