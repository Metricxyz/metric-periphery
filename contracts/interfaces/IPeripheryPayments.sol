// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPeripheryPayments
/// @notice Token and ETH settlement helpers for router periphery contracts.
interface IPeripheryPayments {
  /// @notice Unwrap all WETH held by this contract and send ETH to `recipient`.
  /// @param amountMinimum Minimum WETH balance required before unwrapping.
  /// @param recipient Address that receives the unwrapped ETH.
  function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;

  /// @notice Transfer all of `token` held by this contract to `recipient`.
  /// @param token ERC-20 to sweep.
  /// @param amountMinimum Minimum token balance required before sweeping.
  /// @param recipient Address that receives the swept tokens.
  function sweepToken(address token, uint256 amountMinimum, address recipient) external payable;

  /// @notice Refund all ETH held by this contract to `msg.sender`.
  function refundETH() external payable;
}
