// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BoundedReturnData} from "../libraries/BoundedReturnData.sol";
import {ISequence} from "../interfaces/ISequence.sol";

/// @title Sequence
/// @notice Router calls with per-step success and failure policies.
abstract contract Sequence is ISequence, ReentrancyGuardTransient {
  /// @dev Dispatchers leave locking to each delegated operation.
  modifier whenNotEntered() {
    if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
    _;
  }

  /// @inheritdoc ISequence
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    override
    whenNotEntered
    returns (bytes[] memory results, StepStatus[] memory statuses)
  {
    results = new bytes[](calls.length);
    statuses = new StepStatus[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      SequenceCall calldata step = calls[i];
      (bool success, bytes memory result) = _executeSequenceStep(step.data);
      results[i] = result;
      statuses[i] = success ? StepStatus.SUCCESS : StepStatus.FAILURE;

      if (success) {
        if (step.onSuccess == OnStepSuccess.STOP) break;
      } else {
        if (step.onFailure == OnStepFailure.STOP) break;
        if (step.onFailure == OnStepFailure.REVERT) {
          revert SequenceFailed(results, statuses);
        }
      }
    }
  }

  function _executeSequenceStep(bytes calldata data) private returns (bool success, bytes memory result) {
    success = LowLevelCall.delegatecallNoReturn(address(this), data);
    result = BoundedReturnData.read();
  }
}
