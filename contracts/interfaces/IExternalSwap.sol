// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IExternalSwap
/// @notice External swap parameters and settlement results.
interface IExternalSwap {
  /// @notice Recipient received less tokenOut than amountOutMinimum.
  error ExternalSwapInsufficientOutput(uint256 amountOut, uint256 amountOutMinimum);
  /// @notice External router is this router or has no code.
  error InvalidExternalRouter(address target);
  /// @notice Recipient is the executor.
  error InvalidExternalSwapRecipient(address recipient);
  /// @notice Native refund requested for a tokenIn other than WETH.
  error InvalidNativeRefundToken(address token);
  /// @notice External router calldata is empty.
  error EmptyExternalRouterCalldata();
  /// @notice tokenIn equals tokenOut.
  error SameTokenExternalSwap();
  /// @notice External router reverted without revert data.
  error ExternalSwapFailed();
  /// @notice Router tokenIn or recipient tokenOut balance decreased during the swap.
  error ExternalSwapBalanceMismatch(address token, address account, uint256 expectedBalance, uint256 actualBalance);

  /// @notice External swap parameters.
  /// @param tokenIn ERC-20 sold; use WETH for native input.
  /// @param tokenOut ERC-20 bought.
  /// @param amountInMaximum Input sent to the executor and approved to externalRouter.
  /// @param amountOutMinimum Minimum tokenOut balance increase of recipient.
  /// @param externalRouter Contract the executor approves and calls; must pull tokenIn itself.
  /// @param externalRouterCalldata Calldata for externalRouter.
  /// @param recipient Address that receives tokenOut.
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

  /// @notice Perform an arbitrary external swap that requires approval and no callback settlement.
  /// @dev Recipient must not be the executor. External calldata must send tokenOut to recipient or the executor.
  ///      The executor forwards any output it holds to recipient.
  ///      Caller-funded swaps refund only the unused input from this execution, without sweeping existing balances.
  ///      Router-funded swaps retain unused input for subsequent steps; append a sweep or unwrap to collect leftovers.
  /// @param executor An isolated contract that performs the external swap.
  /// @param payerIsRouter Fund the maximum from this router's token balance without wrapping ETH or pulling caller tokens.
  ///      Use atomically after funding the router; unused input stays with the router.
  /// @param refundAsNative Require WETH input and unwrap caller refunds to ETH.
  ///      When payerIsRouter is true, input must still be WETH but the refund stays wrapped in the router.
  /// @return amountOut Recipient output balance increase, including any output forwarded from the executor.
  /// @return amountSpent Net funded input not returned to the router, floored at zero.
  function externalSwap(address executor, bool payerIsRouter, bool refundAsNative, ExternalSwapParams calldata params)
    external
    payable
    returns (uint256 amountOut, uint256 amountSpent);
}
