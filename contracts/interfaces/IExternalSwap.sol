// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IExternalSwap
/// @notice Standalone swap through an external router, with no MetricOmm pool involved.
interface IExternalSwap {
  /// @notice Swap deadline is in the past.
  /// @param deadline User-provided deadline.
  /// @param timestamp Current block timestamp.
  error DeadlineExpired(uint256 deadline, uint256 timestamp);
  /// @notice Measured output fell below the caller's minimum.
  /// @param amountOut Actual measured output.
  /// @param amountOutMinimum Minimum required output.
  error ExternalSwapInsufficientOutput(uint256 amountOut, uint256 amountOutMinimum);
  /// @notice The external swap target is this router or has no deployed code.
  error InvalidExternalRouter(address target);
  /// @notice External swap carried empty calldata.
  error EmptyExternalRouterCalldata();
  /// @notice External swap requires distinct input and output tokens.
  error SameTokenExternalSwap();
  /// @notice The external router reverted without returning any reason data.
  error ExternalSwapFailed();

  /// @notice This router takes custody of `tokenIn` first, approves `externalRouter` for at most
  ///         `amountInMaximum`, and measures the `tokenOut` balance delta rather than trusting
  ///         `externalRouterCalldata`. Unspent input is refunded to the caller.
  ///         `externalRouterCalldata` must be encoded to spend at most `amountInMaximum` of `tokenIn` and to
  ///         deliver its output to this router, which forwards it to `recipient`. It is not decoded or validated.
  /// @param tokenIn Input token pulled from the caller and approved to `externalRouter`.
  /// @param tokenOut Output token whose balance delta on this router is measured and forwarded to `recipient`.
  /// @param amountInMaximum Cap on the input pulled from the caller and approved to `externalRouter`; unspent
  ///        input is refunded.
  /// @param amountOutMinimum Minimum measured output.
  /// @param externalRouter Caller-selected contract that both receives the call and spends the approved input.
  ///        Must have deployed code and differ from this router.
  /// @param externalRouterCalldata Pre-encoded call for `externalRouter`.
  /// @param recipient Address that receives the measured output.
  /// @param deadline Timestamp after which the swap reverts.
  struct ExternalSwapParams {
    address tokenIn;
    address tokenOut;
    uint128 amountInMaximum;
    uint128 amountOutMinimum;
    address externalRouter;
    bytes externalRouterCalldata;
    address recipient;
    uint256 deadline;
  }

  function externalSwap(ExternalSwapParams calldata params)
    external
    payable
    returns (uint256 amountOut, uint256 amountSpent);
}
