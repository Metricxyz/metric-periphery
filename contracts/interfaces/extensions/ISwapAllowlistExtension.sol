// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISwapAllowlistExtension
/// @notice Per-pool swap allowlist admin and read API.
interface ISwapAllowlistExtension {
  event AllowedToSwapSet(address indexed pool, address indexed swapper, bool allowed);
  event AllowAllSwappersSet(address indexed pool, bool allowed);

  function allowedSwapper(address pool, address swapper) external view returns (bool);

  function allowAllSwappers(address pool) external view returns (bool);

  function setAllowedToSwap(address pool, address swapper, bool allowed) external;

  function setAllowAllSwappers(address pool, bool allowed) external;

  function isAllowedToSwap(address pool, address swapper) external view returns (bool);
}
