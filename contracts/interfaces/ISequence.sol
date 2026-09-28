// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISequence
/// @notice Router calls with per-step success and failure policies.
interface ISequence {
  /// @notice Action after a successful step: run the next step or stop.
  enum OnStepSuccess {
    CONTINUE,
    STOP
  }

  /// @notice Action after a failed step: run the next step, stop, or revert the whole sequence.
  enum OnStepFailure {
    CONTINUE,
    STOP,
    REVERT
  }

  /// @notice Per-step outcome.
  enum StepStatus {
    NOT_EXECUTED,
    SUCCESS,
    FAILURE
  }

  /// @notice One sequence step.
  /// @param data Calldata delegatecalled on the router.
  /// @param onSuccess Action after success.
  /// @param onFailure Action after failure.
  struct SequenceCall {
    bytes data;
    OnStepSuccess onSuccess;
    OnStepFailure onFailure;
  }

  /// @notice A step failed without reverting the sequence.
  /// @param caller Sequence caller.
  /// @param index Index of the failed step.
  /// @param reason Revert selector; zero if revert data is empty.
  event SequenceStepFailed(address indexed caller, uint256 index, bytes4 reason);

  /// @dev Arrays match calls.length; the last non-NOT_EXECUTED status identifies the triggering failure.
  error SequenceFailed(bytes[] results, StepStatus[] statuses);

  /// @dev Delegatecalls this router, preserving caller and value. STOP leaves later results empty and statuses NOT_EXECUTED;
  ///      REVERT rolls back all steps with SequenceFailed. Both returned and error arrays retain calls.length.
  ///      Unexecuted steps have empty results and NOT_EXECUTED status. Each result is capped at 4096 bytes.
  ///      A step can be an encoded multicall, so a route and its cleanup succeed or roll back together. A failed step
  ///      is rolled back, so msg.value stays available to the next one. Native-input swap with fallbacks:
  ///        1. multicall(exactInputSingle on pool A, refundETH)    onSuccess STOP, onFailure CONTINUE
  ///        2. multicall(exactInputSingle on pool B, refundETH)    onSuccess STOP, onFailure CONTINUE
  ///        3. multicall(externalSwap(executor, false, true, params), refundETH)    onFailure REVERT
  ///      With refundAsNative, externalSwap refunds unused input as ETH; refundETH returns ETH above amountInMaximum.
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    returns (bytes[] memory results, StepStatus[] memory statuses);
}
