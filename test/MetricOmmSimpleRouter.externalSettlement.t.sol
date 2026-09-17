// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract MisreportingExecutor {
  function swap(IExternalSwap.ExternalSwapParams calldata params, address payer)
    external
    returns (uint256 amountOut, uint256 amountSpent)
  {
    uint256 output;
    uint256 refund;
    (amountOut, amountSpent, output, refund) =
      abi.decode(params.externalRouterCalldata, (uint256, uint256, uint256, uint256));
    if (refund > 0) IERC20(params.tokenIn).transfer(payer, refund);
    if (output > 0) IERC20(params.tokenOut).transfer(params.recipient, output);
  }
}

contract ExternalSettlementTest is Test {
  MetricOmmSimpleRouter router;
  MisreportingExecutor executor;
  MockERC20Permit input;
  MockERC20Permit output;
  address recipient = address(0x1234);

  function setUp() public {
    router = new MetricOmmSimpleRouter(address(1), address(2));
    executor = new MisreportingExecutor();
    input = new MockERC20Permit("Input", "IN", 18);
    output = new MockERC20Permit("Output", "OUT", 18);
    input.mint(address(this), 100 ether);
    output.mint(address(executor), 100 ether);
    input.approve(address(router), 100 ether);
  }

  function _params(uint256 reportedOutput, uint256 reportedSpent, uint256 deliveredOutput, uint256 refund)
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
      abi.encode(reportedOutput, reportedSpent, deliveredOutput, refund),
      recipient,
      type(uint256).max
    );
  }

  function test_externalSwap_revertsOnInsufficientRefund() public {
    IExternalSwap.ExternalSwapParams memory params = _params(5 ether, 7 ether, 5 ether, 2 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        IExternalSwap.ExternalSwapBalanceMismatch.selector, address(input), address(this), 93 ether, 92 ether
      )
    );
    router.externalSwap(address(executor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_revertsOnOverreportedOutput() public {
    IExternalSwap.ExternalSwapParams memory params = _params(5 ether, 7 ether, 4 ether, 3 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        IExternalSwap.ExternalSwapBalanceMismatch.selector, address(output), recipient, 5 ether, 4 ether
      )
    );
    router.externalSwap(address(executor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_revertsOnReportedSpendAboveBudget() public {
    IExternalSwap.ExternalSwapParams memory params = _params(5 ether, 11 ether, 5 ether, 0);
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapExcessiveInput.selector, 11 ether, 10 ether));
    router.externalSwap(address(executor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_acceptsExtraOutput() public {
    (uint256 amountOut, uint256 spent) =
      router.externalSwap(address(executor), _params(5 ether, 7 ether, 6 ether, 3 ether));
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(output.balanceOf(recipient), 6 ether);
  }

  function test_externalSwap_acceptsExtraRefund() public {
    (uint256 amountOut, uint256 spent) =
      router.externalSwap(address(executor), _params(5 ether, 7 ether, 5 ether, 4 ether));
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 94 ether);
  }
}
