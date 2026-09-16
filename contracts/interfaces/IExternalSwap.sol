// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IExternalSwap
/// @notice External swap parameters and settlement results.
interface IExternalSwap {
  error DeadlineExpired(uint256 deadline, uint256 timestamp);
  error ExternalSwapInsufficientOutput(uint256 amountOut, uint256 amountOutMinimum);
  error InvalidExternalRouter(address target);
  error EmptyExternalRouterCalldata();
  error SameTokenExternalSwap();
  error ExternalSwapFailed();
  error InvalidExternalExecutor(address executor);
  error ExternalSwapExcessiveInput(uint256 amountSpent, uint256 amountInMaximum);
  error ExternalSwapBalanceMismatch(address token, address account, uint256 expectedBalance, uint256 actualBalance);

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

  /// @dev External calldata must send output to the executor (the external target's msg.sender).
  ///      The executor refunds the payer and pays recipient directly; this router verifies their balance changes.
  ///      Existing balances are transferred as bonuses, excluded from reported amounts and minimum output.
  /// @return amountOut Output balance increase during the swap, excluding pre-existing balances.
  /// @return amountSpent Input balance decrease during the swap, floored at zero.
  function externalSwap(ExternalSwapParams calldata params)
    external
    payable
    returns (uint256 amountOut, uint256 amountSpent);
}
