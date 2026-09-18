// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {Sequence} from "../contracts/base/Sequence.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {ISequence} from "../contracts/interfaces/ISequence.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract SimpleRouterSequenceTest is Test {
  MetricOmmSimpleRouter router;
  MockERC20Permit token;
  address recipient = address(0x1234);

  function setUp() public {
    router = new MetricOmmSimpleRouter(address(1), address(2));
    token = new MockERC20Permit("Token", "TOK", 18);
    token.mint(address(router), 10 ether);
  }

  function _calls(bool firstFails) private view returns (ISequence.SequenceCall[] memory calls) {
    calls = new ISequence.SequenceCall[](2);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.sweepToken, (address(token), firstFails ? 11 ether : 0, recipient)),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.CONTINUE
    );
    calls[1] = ISequence.SequenceCall(
      abi.encodeCall(router.sweepToken, (address(token), 0, recipient)),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.REVERT
    );
  }

  function test_sequence_emptyCallsReturnEmptyArrays() public {
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = router.sequence(new ISequence.SequenceCall[](0));
    assertEq(results.length, 0);
    assertEq(statuses.length, 0);
  }

  function test_sequence_continuesAfterFailure() public {
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = router.sequence(_calls(true));
    assertEq(uint8(statuses[0]), 2);
    assertEq(uint8(statuses[1]), 1);
    assertEq(
      results[0],
      abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 11 ether, 10 ether)
    );
    assertEq(token.balanceOf(recipient), 10 ether);
  }

  function test_sequence_stopsAfterFailure() public {
    ISequence.SequenceCall[] memory calls = _calls(true);
    calls[0].onFailure = ISequence.OnStepFailure.STOP;
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = router.sequence(calls);
    assertEq(uint8(statuses[0]), 2);
    assertEq(uint8(statuses[1]), 0);
    assertEq(results[1].length, 0);
    assertEq(token.balanceOf(address(router)), 10 ether);
  }

  function test_sequence_stopsAfterSuccess() public {
    ISequence.SequenceCall[] memory calls = _calls(false);
    calls[0].onSuccess = ISequence.OnStepSuccess.STOP;
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = router.sequence(calls);
    assertEq(uint8(statuses[0]), 1);
    assertEq(uint8(statuses[1]), 0);
    assertEq(results[1].length, 0);
    assertEq(token.balanceOf(recipient), 10 ether);
  }

  function test_sequence_revertRollsBackEarlierSteps() public {
    ISequence.SequenceCall[] memory calls = _calls(false);
    calls[1].data = abi.encodeCall(router.sweepToken, (address(token), 1, recipient));
    bytes memory reason = abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 1, 0);
    bytes[] memory results = new bytes[](2);
    results[1] = reason;
    ISequence.StepStatus[] memory statuses = new ISequence.StepStatus[](2);
    statuses[0] = ISequence.StepStatus.SUCCESS;
    statuses[1] = ISequence.StepStatus.FAILURE;
    vm.expectRevert(abi.encodeWithSelector(ISequence.SequenceFailed.selector, results, statuses));
    router.sequence(calls);
    assertEq(token.balanceOf(address(router)), 10 ether);
    assertEq(token.balanceOf(recipient), 0);
  }

  function test_sequence_revertIncludesEarlierFailuresAndMarksUnexecutedSteps() public {
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](3);
    calls[0] = _calls(true)[0];
    calls[1] = ISequence.SequenceCall(
      abi.encodeCall(router.sweepToken, (address(token), 12 ether, recipient)),
      ISequence.OnStepSuccess.STOP,
      ISequence.OnStepFailure.REVERT
    );
    calls[2] = _calls(false)[0];
    bytes[] memory results = new bytes[](3);
    results[0] =
      abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 11 ether, 10 ether);
    results[1] =
      abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 12 ether, 10 ether);
    ISequence.StepStatus[] memory statuses = new ISequence.StepStatus[](3);
    statuses[0] = ISequence.StepStatus.FAILURE;
    statuses[1] = ISequence.StepStatus.FAILURE;
    vm.expectRevert(abi.encodeWithSelector(ISequence.SequenceFailed.selector, results, statuses));
    router.sequence(calls);
    assertEq(token.balanceOf(address(router)), 10 ether);
    assertEq(token.balanceOf(recipient), 0);
  }

  function test_sequence_preservesBothExpiredSwapReasons() public {
    vm.warp(100);
    IMetricOmmSimpleRouter.ExactInputSingleParams memory primary = IMetricOmmSimpleRouter.ExactInputSingleParams({
      pool: address(3),
      tokenIn: address(token),
      tokenOut: address(4),
      zeroForOne: true,
      amountIn: 10 ether,
      amountOutMinimum: 1 ether,
      recipient: recipient,
      deadline: 99,
      priceLimitX64: 0,
      extensionData: ""
    });
    IExternalSwap.ExternalSwapParams memory fallbackParams = IExternalSwap.ExternalSwapParams({
      tokenIn: primary.tokenIn,
      tokenOut: primary.tokenOut,
      amountInMaximum: primary.amountIn,
      amountOutMinimum: primary.amountOutMinimum,
      externalRouter: address(5),
      externalRouterCalldata: "",
      recipient: recipient,
      deadline: primary.deadline
    });
    bytes[] memory primaryCalls = new bytes[](1);
    primaryCalls[0] = abi.encodeCall(router.exactInputSingle, (primary));
    bytes[] memory fallbackCalls = new bytes[](1);
    fallbackCalls[0] = abi.encodeCall(router.externalSwap, (address(6), false, false, fallbackParams));
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](2);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.multicall, (primaryCalls)), ISequence.OnStepSuccess.STOP, ISequence.OnStepFailure.CONTINUE
    );
    calls[1] = ISequence.SequenceCall(
      abi.encodeCall(router.multicall, (fallbackCalls)), ISequence.OnStepSuccess.STOP, ISequence.OnStepFailure.REVERT
    );
    bytes[] memory results = new bytes[](2);
    results[0] = abi.encodeWithSelector(IMetricOmmSimpleRouter.TransactionExpired.selector, 99, 100);
    results[1] = abi.encodeWithSelector(IExternalSwap.DeadlineExpired.selector, 99, 100);
    ISequence.StepStatus[] memory statuses = new ISequence.StepStatus[](2);
    statuses[0] = ISequence.StepStatus.FAILURE;
    statuses[1] = ISequence.StepStatus.FAILURE;
    vm.expectRevert(abi.encodeWithSelector(ISequence.SequenceFailed.selector, results, statuses));
    router.sequence(calls);
  }

  function test_sequence_preservesCallerAndNativeValue() public {
    address caller = address(0x5678);
    vm.deal(caller, 1 ether);
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](1);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(router.refundETH, ()), ISequence.OnStepSuccess.CONTINUE, ISequence.OnStepFailure.REVERT
    );
    vm.prank(caller);
    router.sequence{value: 1 ether}(calls);
    assertEq(caller.balance, 1 ether);
    assertEq(address(router).balance, 0);
  }
}

contract SequenceReturnDataHarness is Sequence {
  function respond(bytes calldata data, bool fail) external pure {
    bytes memory result = data;
    assembly ("memory-safe") {
      if fail { revert(add(result, 0x20), mload(result)) }
      return(add(result, 0x20), mload(result))
    }
  }
}

contract SequenceReturnDataTest is Test {
  function test_sequence_truncatesLargeSuccessData() public {
    _checkBoundedResult(false);
  }

  function test_sequence_truncatesLargeRevertData() public {
    _checkBoundedResult(true);
  }

  function test_sequence_revertIncludesBoundedSuccessData() public {
    _checkBoundedSequenceFailure(false);
  }

  function test_sequence_revertIncludesBoundedEarlierFailureData() public {
    _checkBoundedSequenceFailure(true);
  }

  function testFuzz_sequence_failurePreservesStatusesForAllCalls(uint8 failureIndex, uint8 trailingSteps) public {
    uint256 failedIndex = bound(uint256(failureIndex), 0, 6);
    uint256 unexecutedSteps = bound(uint256(trailingSteps), 0, 6);
    SequenceReturnDataHarness sequence = new SequenceReturnDataHarness();
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](failedIndex + 1 + unexecutedSteps);
    bytes[] memory results = new bytes[](calls.length);
    ISequence.StepStatus[] memory statuses = new ISequence.StepStatus[](calls.length);
    for (uint256 i; i < calls.length; i++) {
      bytes memory payload = abi.encode(i);
      calls[i] = ISequence.SequenceCall(
        abi.encodeCall(sequence.respond, (payload, i == failedIndex)),
        ISequence.OnStepSuccess.CONTINUE,
        ISequence.OnStepFailure.REVERT
      );
      if (i <= failedIndex) {
        results[i] = payload;
        statuses[i] = i < failedIndex ? ISequence.StepStatus.SUCCESS : ISequence.StepStatus.FAILURE;
      }
    }
    vm.expectRevert(abi.encodeWithSelector(ISequence.SequenceFailed.selector, results, statuses));
    sequence.sequence(calls);
  }

  function _checkBoundedSequenceFailure(bool firstFails) private {
    SequenceReturnDataHarness sequence = new SequenceReturnDataHarness();
    bytes memory payload = new bytes(8192);
    payload[0] = 0xab;
    payload[4095] = 0xcd;
    payload[8191] = 0xef;
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](2);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(sequence.respond, (payload, firstFails)),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.CONTINUE
    );
    calls[1] = ISequence.SequenceCall(
      abi.encodeCall(sequence.respond, (payload, true)), ISequence.OnStepSuccess.STOP, ISequence.OnStepFailure.REVERT
    );
    bytes memory bounded = new bytes(4096);
    bounded[0] = 0xab;
    bounded[4095] = 0xcd;
    bytes[] memory results = new bytes[](2);
    results[0] = bounded;
    results[1] = bounded;
    ISequence.StepStatus[] memory statuses = new ISequence.StepStatus[](2);
    statuses[0] = firstFails ? ISequence.StepStatus.FAILURE : ISequence.StepStatus.SUCCESS;
    statuses[1] = ISequence.StepStatus.FAILURE;
    vm.expectRevert(abi.encodeWithSelector(ISequence.SequenceFailed.selector, results, statuses));
    sequence.sequence(calls);
  }

  function _checkBoundedResult(bool fail) private {
    SequenceReturnDataHarness sequence = new SequenceReturnDataHarness();
    bytes memory payload = new bytes(8192);
    payload[0] = 0xab;
    payload[4095] = 0xcd;
    payload[8191] = 0xef;
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](1);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(sequence.respond, (payload, fail)),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.CONTINUE
    );
    (bytes[] memory results, ISequence.StepStatus[] memory statuses) = sequence.sequence(calls);
    bytes memory expected = new bytes(4096);
    expected[0] = 0xab;
    expected[4095] = 0xcd;
    assertEq(uint8(statuses[0]), fail ? 2 : 1);
    assertEq(results[0], expected);
  }
}
