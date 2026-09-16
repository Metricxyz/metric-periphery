// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExternalSwapExecutor} from "../contracts/base/ExternalSwapExecutor.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {ISequence} from "../contracts/interfaces/ISequence.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";

contract ExternalRouterMock {
  address public executor;

  function swap(address tokenIn, address tokenOut, address recipient, uint256 spend, uint256 output) external {
    executor = msg.sender;
    IERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
    IERC20(tokenOut).transfer(recipient, output);
  }

  function reenter(MetricOmmSimpleRouter router) external {
    router.refundETH();
  }

  function reenterSequence(MetricOmmSimpleRouter router) external {
    router.sequence(new ISequence.SequenceCall[](0));
  }

  function reenterMulticall(MetricOmmSimpleRouter router) external {
    router.multicall(new bytes[](0));
  }

  function fail(uint256 length) external pure {
    bytes memory reason = new bytes(length);
    assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
  }
}

contract SimpleRouterExternalSwapTest is Test {
  MetricOmmSimpleRouter router;
  MockERC20Permit input;
  MockERC20Permit output;
  MockWETH9 weth;
  ExternalRouterMock target;
  address recipient = address(0x1234);

  function setUp() public {
    weth = new MockWETH9();
    ExternalSwapExecutor executor =
      new ExternalSwapExecutor(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
    router = new MetricOmmSimpleRouter(address(weth), address(1), address(executor));
    input = new MockERC20Permit("Input", "IN", 18);
    output = new MockERC20Permit("Output", "OUT", 18);
    target = new ExternalRouterMock();
    input.mint(address(this), 100 ether);
    input.approve(address(router), type(uint256).max);
    output.mint(address(target), 100 ether);
  }

  function _params() private view returns (IExternalSwap.ExternalSwapParams memory) {
    return IExternalSwap.ExternalSwapParams(
      address(input),
      address(output),
      10 ether,
      5 ether,
      address(target),
      abi.encodeCall(
        target.swap, (address(input), address(output), address(router.isolatedExternalExecutor()), 7 ether, 5 ether)
      ),
      recipient,
      type(uint256).max
    );
  }

  function test_externalSwap_refundsPartialFillAndReusesExecutor() public {
    input.mint(address(router), 2 ether);
    output.mint(address(router), 3 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap(_params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 2 ether);
    assertEq(output.balanceOf(address(router)), 3 ether);
    assertEq(output.balanceOf(recipient), 5 ether);
    address first = target.executor();
    assertTrue(first != address(router));
    assertEq(input.balanceOf(first), 0);
    assertEq(input.allowance(first, address(target)), 0);
    assertEq(input.allowance(address(router), address(target)), 0);
    router.externalSwap(_params());
    assertEq(target.executor(), first);
    assertEq(first, address(router.isolatedExternalExecutor()));
    assertEq(input.balanceOf(first), 0);
    assertEq(input.allowance(first, address(target)), 0);
  }

  function test_externalSwap_tokenTransfersBypassRouter() public {
    vm.recordLogs();
    router.externalSwap(_params());
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 transferEvent = keccak256("Transfer(address,address,uint256)");
    bytes32 routerAddress = bytes32(uint256(uint160(address(router))));
    uint256 transfers;
    for (uint256 i; i < logs.length; i++) {
      if (logs[i].topics[0] != transferEvent) continue;
      assertTrue(logs[i].topics[1] != routerAddress);
      assertTrue(logs[i].topics[2] != routerAddress);
      transfers++;
    }
    assertEq(transfers, 5);
  }

  function test_externalSwap_donatesExistingBalancesToNextSwap() public {
    address executor = address(router.isolatedExternalExecutor());
    input.mint(executor, 2 ether);
    output.mint(executor, 3 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    (uint256 amountOut, uint256 spent) = router.externalSwap(params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(executor), 0);
    assertEq(output.balanceOf(executor), 0);
    assertEq(input.balanceOf(address(this)), 95 ether);
    assertEq(output.balanceOf(recipient), 8 ether);

    (amountOut, spent) = router.externalSwap(_params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 88 ether);
    assertEq(output.balanceOf(recipient), 13 ether);
  }

  function test_externalSwap_donationAboveSpendRefundsMoreThanFunding() public {
    address executor = address(router.isolatedExternalExecutor());
    input.mint(executor, 8 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap(_params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 101 ether);
    assertEq(input.balanceOf(executor), 0);
  }

  function test_externalSwap_donationEqualToSpendDoesNotChangeReportedInput() public {
    input.mint(address(router.isolatedExternalExecutor()), 7 ether);
    (, uint256 spent) = router.externalSwap(_params());
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_revertsWhenDonationAloneSatisfiesMinimum() public {
    address executor = address(router.isolatedExternalExecutor());
    output.mint(executor, 3 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.amountOutMinimum = 8 ether;
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 5 ether, 8 ether));
    router.externalSwap(params);
    assertEq(output.balanceOf(executor), 3 ether);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_payerIsRecipient() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.recipient = address(this);
    router.externalSwap(params);
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(output.balanceOf(address(this)), 5 ether);
  }

  function test_externalSwap_fullFillWithoutRefund() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(
      target.swap, (address(input), address(output), address(router.isolatedExternalExecutor()), 10 ether, 5 ether)
    );
    (uint256 amountOut, uint256 spent) = router.externalSwap(params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 10 ether);
    assertEq(input.balanceOf(address(this)), 90 ether);
  }

  function test_externalSwap_mixedNativeAndWethFunding() public {
    vm.deal(address(this), 10 ether);
    weth.deposit{value: 6 ether}();
    weth.approve(address(router), 6 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.tokenIn = address(weth);
    params.externalRouterCalldata = abi.encodeCall(
      target.swap, (address(weth), address(output), address(router.isolatedExternalExecutor()), 7 ether, 5 ether)
    );
    (uint256 amountOut, uint256 spent) = router.externalSwap{value: 4 ether}(params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(weth.balanceOf(address(this)), 3 ether);
    assertEq(weth.balanceOf(address(router)), 0);
    assertEq(address(router).balance, 0);
  }

  function test_executorSwap_revertsOnUnauthorizedCaller() public {
    ExternalSwapExecutor executor = router.isolatedExternalExecutor();
    input.mint(address(executor), 1 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    vm.expectRevert(ExternalSwapExecutor.UnauthorizedCaller.selector);
    executor.swap(params, address(this));
    assertEq(input.balanceOf(address(executor)), 1 ether);
  }

  function test_constructor_revertsOnExecutorWithoutCode() public {
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.InvalidExternalExecutor.selector, address(0)));
    new MetricOmmSimpleRouter(address(weth), address(1), address(0));
    address eoa = address(0x12345);
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.InvalidExternalExecutor.selector, eoa));
    new MetricOmmSimpleRouter(address(weth), address(1), eoa);
  }

  function test_constructor_revertsOnExecutorBoundToAnotherRouter() public {
    address executor = address(router.isolatedExternalExecutor());
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.InvalidExternalExecutor.selector, executor));
    new MetricOmmSimpleRouter(address(weth), address(1), executor);
  }

  function test_executorConstructor_revertsOnZeroRouter() public {
    vm.expectRevert(ExternalSwapExecutor.InvalidRouter.selector);
    new ExternalSwapExecutor(address(0));
  }

  function test_externalSwap_revertsWholeSwapOnSlippage() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.amountOutMinimum = 6 ether;
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 5 ether, 6 ether));
    router.externalSwap(params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(address(target)), 0);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_revertsWhenSpendingBeyondBudget() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(
      target.swap, (address(input), address(output), address(router.isolatedExternalExecutor()), 11 ether, 5 ether)
    );
    vm.expectRevert();
    router.externalSwap(params);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_nativeFundingRefundsUnspentWeth() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.tokenIn = address(weth);
    params.externalRouterCalldata = abi.encodeCall(
      target.swap, (address(weth), address(output), address(router.isolatedExternalExecutor()), 7 ether, 5 ether)
    );
    vm.deal(address(this), 10 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap{value: 10 ether}(params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(weth.balanceOf(address(this)), 3 ether);
    assertEq(address(router).balance, 0);
  }

  function test_externalSwap_revertsOnPaymentReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenter, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(params);
  }

  function test_externalSwap_revertsOnSequenceReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenterSequence, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(params);
  }

  function test_externalSwap_revertsOnMulticallReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenterMulticall, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(params);
  }

  function test_externalSwap_emptyRevertUsesFallbackError() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.fail, (0));
    vm.expectRevert(IExternalSwap.ExternalSwapFailed.selector);
    router.externalSwap(params);
  }

  function test_externalSwap_boundsRevertData() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.fail, (8192));
    vm.expectRevert(new bytes(4096));
    router.externalSwap(params);
  }

  function test_sequence_executesExternalSwap() public {
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](1);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.externalSwap, (_params())), ISequence.OnStepSuccess.CONTINUE, ISequence.OnStepFailure.REVERT
    );
    (bytes[] memory results, bool[] memory successes) = router.sequence(calls);
    assertTrue(successes[0]);
    assertEq(results[0], abi.encode(uint256(5 ether), uint256(7 ether)));
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(output.balanceOf(recipient), 5 ether);
  }
}
