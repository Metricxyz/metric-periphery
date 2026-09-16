// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISequence
/// @notice Router calls with per-step success and failure policies.
interface ISequence {
  enum OnStepSuccess {
    CONTINUE,
    STOP
  }

  enum OnStepFailure {
    CONTINUE,
    STOP,
    REVERT
  }

  struct SequenceCall {
    bytes data;
    OnStepSuccess onSuccess;
    OnStepFailure onFailure;
  }

  error StepFailed(uint256 index, bytes reason);

  /// @dev Delegatecalls this router, preserving caller and value. STOP leaves later results empty/false;
  ///      REVERT rolls back the sequence with StepFailed. Return/revert data is capped at 4096 bytes per step.
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    returns (bytes[] memory results, bool[] memory successes);
}
