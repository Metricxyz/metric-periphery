// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title IDepositAllowlistHook
/// @notice Per-pool deposit allowlist admin and read API.
interface IDepositAllowlistHook {
  event AllowedToDepositSet(address indexed pool, address indexed depositor, bool allowed);

  function allowedDepositor(address pool, address depositor) external view returns (bool);

  function setAllowedToDeposit(address pool, address depositor, bool allowed) external;

  function isAllowedToDeposit(address pool, address depositor) external view returns (bool);
}
