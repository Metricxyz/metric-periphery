// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IExternalSwap
/// @notice External swap parameters and settlement results.
interface IExternalSwap {
  error DeadlineExpired(uint256 deadline, uint256 timestamp);
  error ExternalSwapInsufficientOutput(uint256 amountOut, uint256 amountOutMinimum);
  error InvalidExternalRouter(address target);
  error InvalidExternalSwapRecipient(address recipient);
  error EmptyExternalRouterCalldata();
  error SameTokenExternalSwap();
  error ExternalSwapFailed();
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

  /// @dev       Recipient must not be the executor. External calldata may send tokenOut to recipient or to the executor.
  ///      Any output held by the executor is forwarded to recipient before this router measures the output balance increase.
  ///      The executor refunds unspent tokenIn to this router; router refunds and recipient output are verified by balance changes.
  ///      Collect refunds with sweepToken, or unwrapWETH9 for WETH, in the same multicall.
  ///      To receive native output, set recipient to this router and append unwrapWETH9 in the same multicall.
  ///      refundETH returns only ETH that was never wrapped, not WETH refunds.
  ///      Existing executor input balances are refunded as bonuses, excluded from reported input spent.
  ///      Existing recipient output balances do not count toward output; forwarded executor balances do count.
  /// @return amountOut Recipient output balance increase, including any output forwarded from the executor.
  /// @return amountSpent Input balance decrease during the swap, floored at zero.
  function externalSwap(address executor, ExternalSwapParams calldata params)
    external
    payable
    returns (uint256 amountOut, uint256 amountSpent);
}
