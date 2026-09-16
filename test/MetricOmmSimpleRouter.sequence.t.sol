// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExternalSwapExecutor} from "../contracts/base/ExternalSwapExecutor.sol";
import {Test} from "forge-std/Test.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {Sequence} from "../contracts/base/Sequence.sol";
import {ISequence} from "../contracts/interfaces/ISequence.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract SimpleRouterSequenceTest is Test {
  MetricOmmSimpleRouter router;
  MockERC20Permit token;
  address recipient = address(0x1234);

  function setUp() public {
    ExternalSwapExecutor executor =
      new ExternalSwapExecutor(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
    router = new MetricOmmSimpleRouter(address(1), address(2), address(executor));
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

  function test_sequence_continuesAfterFailure() public {
    (bytes[] memory results, bool[] memory successes) = router.sequence(_calls(true));
    assertFalse(successes[0]);
    assertTrue(successes[1]);
    assertEq(
      results[0],
      abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 11 ether, 10 ether)
    );
    assertEq(token.balanceOf(recipient), 10 ether);
  }

  function test_sequence_stopsAfterFailure() public {
    ISequence.SequenceCall[] memory calls = _calls(true);
    calls[0].onFailure = ISequence.OnStepFailure.STOP;
    (bytes[] memory results, bool[] memory successes) = router.sequence(calls);
    assertFalse(successes[0]);
    assertFalse(successes[1]);
    assertEq(results[1].length, 0);
    assertEq(token.balanceOf(address(router)), 10 ether);
  }

  function test_sequence_stopsAfterSuccess() public {
    ISequence.SequenceCall[] memory calls = _calls(false);
    calls[0].onSuccess = ISequence.OnStepSuccess.STOP;
    (bytes[] memory results, bool[] memory successes) = router.sequence(calls);
    assertTrue(successes[0]);
    assertFalse(successes[1]);
    assertEq(results[1].length, 0);
    assertEq(token.balanceOf(recipient), 10 ether);
  }

  function test_sequence_revertRollsBackEarlierSteps() public {
    ISequence.SequenceCall[] memory calls = _calls(false);
    calls[1].data = abi.encodeCall(router.sweepToken, (address(token), 1, recipient));
    bytes memory reason = abi.encodeWithSignature("InsufficientToken(address,uint256,uint256)", address(token), 1, 0);
    vm.expectRevert(abi.encodeWithSelector(ISequence.StepFailed.selector, 1, reason));
    router.sequence(calls);
    assertEq(token.balanceOf(address(router)), 10 ether);
    assertEq(token.balanceOf(recipient), 0);
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
    (bytes[] memory results, bool[] memory successes) = sequence.sequence(calls);
    bytes memory expected = new bytes(4096);
    expected[0] = 0xab;
    expected[4095] = 0xcd;
    assertEq(successes[0], !fail);
    assertEq(results[0], expected);
  }
}
