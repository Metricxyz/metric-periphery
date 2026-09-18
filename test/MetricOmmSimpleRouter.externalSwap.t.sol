// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExternalSwapExecutor} from "../contracts/base/ExternalSwapExecutor.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {ISequence} from "../contracts/interfaces/ISequence.sol";
import {PeripheryPayments} from "../contracts/base/PeripheryPayments.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";

contract ExternalRouterMock {
  address public executor;

  function swap(address tokenIn, address tokenOut, address recipient, uint256 spend, uint256 output) external {
    executor = msg.sender;
    IERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
    IERC20(tokenOut).transfer(recipient, output);
  }

  function swapToCaller(address tokenIn, address tokenOut, uint256 spend, uint256 output) external {
    executor = msg.sender;
    IERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
    IERC20(tokenOut).transfer(msg.sender, output);
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
  ExternalSwapExecutor swapExecutor;
  MockERC20Permit input;
  MockERC20Permit output;
  MockWETH9 weth;
  ExternalRouterMock target;
  address recipient = address(this);

  receive() external payable {}

  function setUp() public {
    weth = new MockWETH9();
    router = new MetricOmmSimpleRouter(address(weth), address(1));
    swapExecutor = new ExternalSwapExecutor(address(router));
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
      abi.encodeCall(target.swap, (address(input), address(output), recipient, 7 ether, 5 ether)),
      recipient,
      type(uint256).max
    );
  }

  function test_externalSwap_refundsPartialFillAndReusesExecutor() public {
    input.mint(address(router), 2 ether);
    output.mint(address(router), 3 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), _params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 5 ether);
    assertEq(output.balanceOf(address(router)), 3 ether);
    assertEq(output.balanceOf(recipient), 5 ether);
    address first = target.executor();
    assertTrue(first != address(router));
    assertEq(input.balanceOf(first), 0);
    assertEq(input.allowance(first, address(target)), 0);
    assertEq(input.allowance(address(router), address(target)), 0);
    router.externalSwap(address(swapExecutor), _params());
    assertEq(target.executor(), first);
    assertEq(first, address(swapExecutor));
    assertEq(input.balanceOf(first), 0);
    assertEq(input.allowance(first, address(target)), 0);
  }

  function test_externalSwap_onlyRefundPassesThroughRouter() public {
    vm.recordLogs();
    router.externalSwap(address(swapExecutor), _params());
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 transferEvent = keccak256("Transfer(address,address,uint256)");
    bytes32 routerAddress = bytes32(uint256(uint160(address(router))));
    uint256 transfers;
    uint256 refunds;
    uint256 directOutputs;
    for (uint256 i; i < logs.length; i++) {
      if (logs[i].topics[0] != transferEvent) continue;
      assertTrue(logs[i].topics[1] != routerAddress);
      if (logs[i].topics[2] == routerAddress) {
        assertEq(logs[i].emitter, address(input));
        assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(swapExecutor)))));
        assertEq(abi.decode(logs[i].data, (uint256)), 3 ether);
        refunds++;
      }
      if (logs[i].emitter == address(output)) {
        assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(target)))));
        assertEq(logs[i].topics[2], bytes32(uint256(uint160(recipient))));
        assertEq(abi.decode(logs[i].data, (uint256)), 5 ether);
        directOutputs++;
      }
      transfers++;
    }
    assertEq(transfers, 4);
    assertEq(refunds, 1);
    assertEq(directOutputs, 1);
  }

  function test_externalSwap_refundsExistingInputAndForwardsExecutorOutput() public {
    address executor = address(swapExecutor);
    input.mint(executor, 2 ether);
    output.mint(executor, 3 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), params);
    assertEq(amountOut, 8 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(executor), 0);
    assertEq(output.balanceOf(executor), 0);
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 5 ether);
    assertEq(output.balanceOf(recipient), 8 ether);

    (amountOut, spent) = router.externalSwap(address(swapExecutor), _params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 80 ether);
    assertEq(input.balanceOf(address(router)), 8 ether);
    assertEq(output.balanceOf(recipient), 13 ether);
  }

  function test_externalSwap_donationAboveSpendRefundsMoreThanFunding() public {
    address executor = address(swapExecutor);
    input.mint(executor, 8 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), _params());
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 11 ether);
    assertEq(input.balanceOf(executor), 0);
  }

  function test_externalSwap_donationEqualToSpendDoesNotChangeReportedInput() public {
    input.mint(address(swapExecutor), 7 ether);
    (, uint256 spent) = router.externalSwap(address(swapExecutor), _params());
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 10 ether);
  }

  function test_externalSwap_forwardedExecutorBalanceCountsTowardMinimum() public {
    address executor = address(swapExecutor);
    output.mint(executor, 3 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.amountOutMinimum = 8 ether;
    (uint256 amountOut,) = router.externalSwap(address(swapExecutor), params);
    assertEq(amountOut, 8 ether);
    assertEq(output.balanceOf(executor), 0);
    assertEq(output.balanceOf(recipient), 8 ether);
  }

  function test_externalSwap_deliversOutputDirectlyToRouter() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.recipient = address(router);
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(output), address(router), 7 ether, 5 ether));
    router.externalSwap(address(swapExecutor), params);
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 3 ether);
    assertEq(output.balanceOf(address(router)), 5 ether);
    assertEq(output.balanceOf(address(swapExecutor)), 0);
  }

  function test_externalSwap_rejectsExecutorAsRecipient() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.recipient = address(swapExecutor);
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.InvalidExternalSwapRecipient.selector, params.recipient));
    router.externalSwap(address(swapExecutor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(address(swapExecutor)), 0);
    assertEq(target.executor(), address(0));
  }

  function test_externalSwap_deliversOutputToThirdParty() public {
    address thirdParty = address(0x1234);
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.recipient = thirdParty;
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(output), thirdParty, 7 ether, 5 ether));
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(output.balanceOf(thirdParty), 5 ether);
    assertEq(output.balanceOf(address(this)), 0);
    assertEq(output.balanceOf(address(swapExecutor)), 0);
    assertEq(input.balanceOf(address(router)), 3 ether);
  }

  function test_externalSwap_forwardsOutputWhenExternalRouterPaysCaller() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.recipient = address(0x1234);
    params.externalRouterCalldata =
      abi.encodeCall(target.swapToCaller, (address(input), address(output), 7 ether, 5 ether));
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(output.balanceOf(address(swapExecutor)), 0);
    assertEq(output.balanceOf(params.recipient), 5 ether);
    assertEq(input.balanceOf(address(router)), 3 ether);
    assertEq(input.allowance(address(swapExecutor), address(target)), 0);
  }

  function test_externalSwap_revertsOnInsufficientForwardedOutput() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata =
      abi.encodeCall(target.swapToCaller, (address(input), address(output), 7 ether, 4 ether));
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 4 ether, 5 ether));
    router.externalSwap(address(swapExecutor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(output.balanceOf(address(swapExecutor)), 0);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_existingRecipientBalanceDoesNotCountAsOutput() public {
    output.mint(recipient, 10 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.amountOutMinimum = 6 ether;
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 5 ether, 6 ether));
    router.externalSwap(address(swapExecutor), params);
    assertEq(output.balanceOf(recipient), 10 ether);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_fullFillWithoutRefund() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(output), recipient, 10 ether, 5 ether));
    (uint256 amountOut, uint256 spent) = router.externalSwap(address(swapExecutor), params);
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
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(weth), address(output), recipient, 7 ether, 5 ether));
    (uint256 amountOut, uint256 spent) = router.externalSwap{value: 4 ether}(address(swapExecutor), params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(weth.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(router)), 3 ether);
    assertEq(address(router).balance, 0);
  }

  function test_executorSwap_revertsOnUnauthorizedCaller() public {
    ExternalSwapExecutor executor = swapExecutor;
    input.mint(address(executor), 1 ether);
    IExternalSwap.ExternalSwapParams memory params = _params();
    vm.expectRevert(ExternalSwapExecutor.UnauthorizedCaller.selector);
    executor.swap(params);
    assertEq(input.balanceOf(address(executor)), 1 ether);
  }

  function test_externalSwap_revertsOnExecutorWithoutCode() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    vm.expectRevert();
    router.externalSwap(address(0), params);
    address eoa = address(0x12345);
    vm.expectRevert();
    router.externalSwap(eoa, params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(eoa), 0);
    assertEq(input.balanceOf(address(target)), 0);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_revertsOnExecutorBoundToAnotherRouter() public {
    MetricOmmSimpleRouter otherRouter = new MetricOmmSimpleRouter(address(weth), address(1));
    ExternalSwapExecutor wrongExecutor = new ExternalSwapExecutor(address(otherRouter));
    IExternalSwap.ExternalSwapParams memory params = _params();
    vm.expectRevert(ExternalSwapExecutor.UnauthorizedCaller.selector);
    router.externalSwap(address(wrongExecutor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(address(wrongExecutor)), 0);
    assertEq(input.balanceOf(address(target)), 0);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_usesExecutorSelectedForEachSwap() public {
    router.externalSwap(address(swapExecutor), _params());
    ExternalSwapExecutor secondExecutor = new ExternalSwapExecutor(address(router));
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(output), recipient, 7 ether, 5 ether));

    (uint256 amountOut, uint256 spent) = router.externalSwap(address(secondExecutor), params);

    assertEq(target.executor(), address(secondExecutor));
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(input.balanceOf(address(this)), 80 ether);
    assertEq(input.balanceOf(address(router)), 6 ether);
    assertEq(output.balanceOf(recipient), 10 ether);
    assertEq(input.balanceOf(address(secondExecutor)), 0);
    assertEq(input.allowance(address(secondExecutor), address(target)), 0);
  }

  function test_executorConstructor_revertsOnZeroRouter() public {
    vm.expectRevert(ExternalSwapExecutor.InvalidRouter.selector);
    new ExternalSwapExecutor(address(0));
  }

  function test_externalSwap_revertsWholeSwapOnSlippage() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.amountOutMinimum = 6 ether;
    vm.expectRevert(abi.encodeWithSelector(IExternalSwap.ExternalSwapInsufficientOutput.selector, 5 ether, 6 ether));
    router.externalSwap(address(swapExecutor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(address(target)), 0);
    assertEq(output.balanceOf(recipient), 0);
  }

  function test_externalSwap_revertsWhenSpendingBeyondBudget() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(output), recipient, 11 ether, 5 ether));
    vm.expectRevert();
    router.externalSwap(address(swapExecutor), params);
    assertEq(input.balanceOf(address(this)), 100 ether);
  }

  function test_externalSwap_nativeFundingRefundsUnspentWethToRouter() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.tokenIn = address(weth);
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(weth), address(output), recipient, 7 ether, 5 ether));
    vm.deal(address(this), 10 ether);
    (uint256 amountOut, uint256 spent) = router.externalSwap{value: 10 ether}(address(swapExecutor), params);
    assertEq(amountOut, 5 ether);
    assertEq(spent, 7 ether);
    assertEq(weth.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(router)), 3 ether);
    assertEq(address(router).balance, 0);
  }

  function test_multicall_sweepsTokenRefund() public {
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), _params()));
    calls[1] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    bytes[] memory results = router.multicall(calls);
    assertEq(results[0], abi.encode(uint256(5 ether), uint256(7 ether)));
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 0);
    assertEq(output.balanceOf(recipient), 5 ether);
  }

  function _nativeInputParams() private view returns (IExternalSwap.ExternalSwapParams memory params) {
    params = _params();
    params.tokenIn = address(weth);
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(weth), address(output), recipient, 7 ether, 5 ether));
  }

  function test_multicall_unwrapsInputRefundAndRefundsUnusedEth() public {
    vm.deal(address(this), 12 ether);
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), _nativeInputParams()));
    calls[1] = abi.encodeCall(router.unwrapWETH9, (0, address(this)));
    calls[2] = abi.encodeCall(router.refundETH, ());
    router.multicall{value: 12 ether}(calls);
    assertEq(address(this).balance, 5 ether);
    assertEq(weth.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(router)), 0);
    assertEq(address(router).balance, 0);
    assertEq(output.balanceOf(recipient), 5 ether);
  }

  function test_multicall_keepsNativeInputRefundWrapped() public {
    vm.deal(address(this), 10 ether);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), _nativeInputParams()));
    calls[1] = abi.encodeCall(router.sweepToken, (address(weth), 0, address(this)));
    router.multicall{value: 10 ether}(calls);
    assertEq(address(this).balance, 0);
    assertEq(weth.balanceOf(address(this)), 3 ether);
    assertEq(weth.balanceOf(address(router)), 0);
    assertEq(output.balanceOf(recipient), 5 ether);
  }

  function _fundWethOutput(address outputRecipient) private returns (IExternalSwap.ExternalSwapParams memory params) {
    vm.deal(address(this), 5 ether);
    weth.deposit{value: 5 ether}();
    assertTrue(weth.transfer(address(target), 5 ether));
    params = _params();
    params.tokenOut = address(weth);
    params.recipient = outputRecipient;
    params.externalRouterCalldata =
      abi.encodeCall(target.swap, (address(input), address(weth), outputRecipient, 7 ether, 5 ether));
  }

  function test_multicall_deliversWrappedOutputDirectlyAndSweepsRefund() public {
    IExternalSwap.ExternalSwapParams memory params = _fundWethOutput(recipient);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), params));
    calls[1] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    router.multicall(calls);
    assertEq(weth.balanceOf(recipient), 5 ether);
    assertEq(recipient.balance, 0);
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 0);
  }

  function test_multicall_unwrapsOutputAndSweepsRefund() public {
    IExternalSwap.ExternalSwapParams memory params = _fundWethOutput(address(router));
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), params));
    calls[1] = abi.encodeCall(router.unwrapWETH9, (params.amountOutMinimum, recipient));
    calls[2] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    router.multicall(calls);
    assertEq(recipient.balance, 5 ether);
    assertEq(weth.balanceOf(recipient), 0);
    assertEq(weth.balanceOf(address(router)), 0);
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 0);
  }

  function test_multicall_unwrapsOutputForwardedFromExecutor() public {
    IExternalSwap.ExternalSwapParams memory params = _fundWethOutput(address(router));
    params.externalRouterCalldata =
      abi.encodeCall(target.swapToCaller, (address(input), address(weth), 7 ether, 5 ether));
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), params));
    calls[1] = abi.encodeCall(router.unwrapWETH9, (params.amountOutMinimum, recipient));
    calls[2] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    bytes[] memory results = router.multicall(calls);
    assertEq(results[0], abi.encode(uint256(5 ether), uint256(7 ether)));
    assertEq(recipient.balance, 5 ether);
    assertEq(weth.balanceOf(address(swapExecutor)), 0);
    assertEq(weth.balanceOf(address(router)), 0);
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 0);
  }

  function test_multicall_failedUnwrapRollsBackSwap() public {
    IExternalSwap.ExternalSwapParams memory params = _fundWethOutput(address(router));
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), params));
    calls[1] = abi.encodeCall(router.unwrapWETH9, (params.amountOutMinimum, address(input)));
    calls[2] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    vm.expectRevert(PeripheryPayments.ETHTransferFailed.selector);
    router.multicall(calls);
    assertEq(input.balanceOf(address(this)), 100 ether);
    assertEq(input.balanceOf(address(target)), 0);
    assertEq(input.balanceOf(address(router)), 0);
    assertEq(weth.balanceOf(address(target)), 5 ether);
    assertEq(weth.balanceOf(address(router)), 0);
  }

  function test_sequence_fallbackMulticallSettlesRefund() public {
    bytes[] memory fallbackCalls = new bytes[](2);
    fallbackCalls[0] = abi.encodeCall(router.externalSwap, (address(swapExecutor), _params()));
    fallbackCalls[1] = abi.encodeCall(router.sweepToken, (address(input), 0, address(this)));
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](2);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.sweepToken, (address(output), 1, recipient)),
      ISequence.OnStepSuccess.STOP,
      ISequence.OnStepFailure.CONTINUE
    );
    calls[1] = ISequence.SequenceCall(
      abi.encodeCall(router.multicall, (fallbackCalls)), ISequence.OnStepSuccess.STOP, ISequence.OnStepFailure.REVERT
    );
    (, ISequence.StepStatus[] memory statuses) = router.sequence(calls);
    assertEq(uint8(statuses[0]), uint8(ISequence.StepStatus.FAILURE));
    assertEq(uint8(statuses[1]), uint8(ISequence.StepStatus.SUCCESS));
    assertEq(input.balanceOf(address(this)), 93 ether);
    assertEq(input.balanceOf(address(router)), 0);
    assertEq(output.balanceOf(recipient), 5 ether);
  }

  function test_externalSwap_revertsOnPaymentReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenter, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(address(swapExecutor), params);
  }

  function test_externalSwap_revertsOnSequenceReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenterSequence, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(address(swapExecutor), params);
  }

  function test_externalSwap_revertsOnMulticallReentry() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.reenterMulticall, (router));
    vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    router.externalSwap(address(swapExecutor), params);
  }

  function test_externalSwap_emptyRevertUsesFallbackError() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.fail, (0));
    vm.expectRevert(IExternalSwap.ExternalSwapFailed.selector);
    router.externalSwap(address(swapExecutor), params);
  }

  function test_externalSwap_boundsRevertData() public {
    IExternalSwap.ExternalSwapParams memory params = _params();
    params.externalRouterCalldata = abi.encodeCall(target.fail, (8192));
    vm.expectRevert(new bytes(4096));
    router.externalSwap(address(swapExecutor), params);
  }

  function test_sequence_executesExternalSwap() public {
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](1);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.externalSwap, (address(swapExecutor), _params())),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.REVERT
    );
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = router.sequence(calls);
    assertEq(uint8(statuses[0]), 1);
    assertEq(results[0], abi.encode(uint256(5 ether), uint256(7 ether)));
    assertEq(input.balanceOf(address(this)), 90 ether);
    assertEq(input.balanceOf(address(router)), 3 ether);
    assertEq(output.balanceOf(recipient), 5 ether);
  }
}
