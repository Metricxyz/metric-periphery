// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title ISwapAllowlistHook
/// @notice Per-pool swap allowlist admin and read API.
interface ISwapAllowlistHook {
  event AllowedToSwapSet(address indexed pool, address indexed swapper, bool allowed);

  function allowedSwapper(address pool, address swapper) external view returns (bool);

  function setAllowedToSwap(address pool, address swapper, bool allowed) external;

  function isAllowedToSwap(address pool, address swapper) external view returns (bool);
}
