// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExternalSwapExecutor} from "../contracts/base/ExternalSwapExecutor.sol";
import {Test} from "forge-std/Test.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {ISequence} from "../contracts/interfaces/ISequence.sol";
import {IExternalSwap} from "../contracts/interfaces/IExternalSwap.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract SequenceSecurityTest is Test {
  MetricOmmSimpleRouter router;
  ExternalSwapExecutor swapExecutor;
  MockERC20Permit token;
  MockERC20Permit dummy;
  address victim = address(0x1234);
  address attacker = address(0x5678);

  function setUp() public {
    token = new MockERC20Permit("Token", "TOK", 18);
    dummy = new MockERC20Permit("Dummy", "DUM", 18);
    router = new MetricOmmSimpleRouter(address(2), address(1));
    swapExecutor = new ExternalSwapExecutor(address(router));
    token.mint(victim, 100 ether);
    vm.prank(victim);
    token.approve(address(router), type(uint256).max);
  }

  function test_sequence_cannotExecuteTokenTransferFrom() public {
    ISequence.SequenceCall[] memory calls = new ISequence.SequenceCall[](1);
    calls[0] = ISequence.SequenceCall(
      abi.encodeCall(token.transferFrom, (victim, attacker, 100 ether)),
      ISequence.OnStepSuccess.CONTINUE,
      ISequence.OnStepFailure.REVERT
    );
    vm.prank(attacker);
    vm.expectRevert(abi.encodeWithSelector(ISequence.StepFailed.selector, 0, bytes("")));
    router.sequence(calls);
    assertEq(token.balanceOf(attacker), 0);
    assertEq(token.balanceOf(victim), 100 ether);
  }

  function test_externalSwap_cannotSpendVictimRouterAllowance() public {
    IExternalSwap.ExternalSwapParams memory params = IExternalSwap.ExternalSwapParams(
      address(dummy),
      address(token),
      0,
      0,
      address(token),
      abi.encodeCall(token.transferFrom, (victim, attacker, 100 ether)),
      attacker,
      type(uint256).max
    );
    vm.prank(attacker);
    vm.expectRevert();
    router.externalSwap(address(swapExecutor), params);
    assertEq(token.balanceOf(attacker), 0);
    assertEq(token.balanceOf(victim), 100 ether);
  }
}
