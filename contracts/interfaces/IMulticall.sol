// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMulticall
/// @notice Batch multiple calls to this contract in one transaction.
interface IMulticall {
  /// @notice Executes each calldata element on this contract via delegatecall.
  /// @param data Encoded function calls to batch.
  /// @return results Return data for each batched call, in order.
  function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
