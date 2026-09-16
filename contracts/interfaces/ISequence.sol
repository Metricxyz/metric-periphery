// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISequence
/// @notice Executes an ordered list of calls against this contract or external targets, with per-step control over
///         what happens after each call succeeds or fails.
interface ISequence {
  /// @notice What to do once a step resolves.
  enum OnStepSuccess {
    CONTINUE,
    STOP
  }

  enum OnStepFailure {
    CONTINUE,
    STOP,
    REVERT
  }

  /// @notice One step of a sequence.
  /// @param target Call target. `address(this)` is delegatecalled, sharing this call's storage and transient
  ///        context, same as `multicall`; any other address receives a regular external call with no value forwarded.
  /// @param data Encoded call.
  /// @param onSuccess Outcome applied when the step succeeds.
  /// @param onFailure Outcome applied when the step reverts.
  struct SequenceCall {
    address target;
    bytes data;
    OnStepSuccess onSuccess;
    OnStepFailure onFailure;
  }

  /// @notice A sequence step reverted; `REVERT` outcomes bubble this instead of the raw revert data.
  /// @param index Index of the step in the `calls` array.
  /// @param reason Revert data returned by the step.
  error StepFailed(uint256 index, bytes reason);

  /// @notice Executes `calls` in order, applying each step's resolved outcome before moving on.
  /// @dev `STOP` ends execution without reverting the transaction; steps at or after it are left unexecuted, with
  ///      empty results and `false` successes. `REVERT` (failure-only) bubbles the step's index and revert data.
  /// @param calls Ordered steps to execute.
  /// @return results Return or revert data for each executed step, in order.
  /// @return successes Whether each executed step succeeded.
  function sequence(SequenceCall[] calldata calls)
    external
    payable
    returns (bytes[] memory results, bool[] memory successes);
}
