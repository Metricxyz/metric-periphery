// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IWETH9
/// @notice Minimal wrapped Ether surface (`deposit` / `withdraw`) used by router periphery payment paths.
interface IWETH9 {
  function deposit() external payable;

  function withdraw(uint256) external;
}
