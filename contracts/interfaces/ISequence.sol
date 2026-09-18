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

  enum StepStatus {
    NOT_EXECUTED,
    SUCCESS,
    FAILURE
  }

  struct SequenceCall {
    bytes data;
    OnStepSuccess onSuccess;
    OnStepFailure onFailure;
  }

  /// @dev Arrays match calls.length; the last non-NOT_EXECUTED status identifies the triggering failure.
  error SequenceFailed(bytes[] results, StepStatus[] statuses);

  /// @dev Delegatecalls this router, preserving caller and value. STOP leaves later results empty and statuses NOT_EXECUTED;
  ///      REVERT rolls back all steps with SequenceFailed. Both returned and error arrays retain calls.length.
  ///      Unexecuted steps have empty results and NOT_EXECUTED status. Each result is capped at 4096 bytes.
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    returns (bytes[] memory results, StepStatus[] memory statuses);
}
