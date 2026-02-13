// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title Interface for WETH9 (Wrapped Ether)
interface IWETH9 {
  function deposit() external payable;

  function withdraw(uint256) external;
}
