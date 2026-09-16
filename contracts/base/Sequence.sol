// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ISequence} from "../interfaces/ISequence.sol";

/// @title Sequence
/// @notice Executes an ordered list of calls against this contract or external targets, with per-step control over
///         what happens after each call succeeds or fails.
abstract contract Sequence is ISequence, ReentrancyGuardTransient {
  /// @inheritdoc ISequence
  /// @dev Steps at or after a `STOP` are left at their zero values (empty `results[i]`, `successes[i] == false`).
  ///      Rejects nested top-level entry, but does not itself hold the lock: a step that delegatecalls back into
  ///      this router reaches a `nonReentrant` leaf that acquires and releases it normally.
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    override
    returns (bytes[] memory results, bool[] memory successes)
  {
    if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
    results = new bytes[](calls.length);
    successes = new bool[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      SequenceCall calldata step = calls[i];
      (bool success, bytes memory result) = _executeSequenceStep(step.target, step.data);
      results[i] = result;
      successes[i] = success;

      if (success) {
        if (step.onSuccess == OnStepSuccess.STOP) break;
      } else {
        if (step.onFailure == OnStepFailure.STOP) break;
        if (step.onFailure == OnStepFailure.REVERT) {
          revert StepFailed(i, result);
        }
      }
    }
  }

  /// @dev `target == address(this)` delegatecalls, sharing this call's storage and transient context, same as
  ///      `multicall`; any other target receives a regular external call with no value forwarded. Only a bounded
  ///      prefix of return/revert data is copied so a target cannot force an unbounded allocation in this frame.
  function _executeSequenceStep(address target, bytes calldata data)
    private
    returns (bool success, bytes memory result)
  {
    assembly ("memory-safe") {
      switch eq(target, address())
      case 1 { success := delegatecall(gas(), target, data.offset, data.length, 0, 0) }
      default { success := call(gas(), target, 0, data.offset, data.length, 0, 0) }

      let size := returndatasize()
      if gt(size, 4096) { size := 4096 }
      result := mload(0x40)
      mstore(result, size)
      returndatacopy(add(result, 0x20), 0, size)
      mstore(0x40, and(add(add(result, size), 0x3f), not(0x1f)))
    }
  }
}
