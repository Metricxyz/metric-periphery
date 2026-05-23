// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title HookPermissions
/// @notice Helpers for combining subhook permission bitmasks.
library HookPermissions {
  function orFlags(uint16 a, uint16 b) internal pure returns (uint16) {
    return a | b;
  }

  function orFlags(uint16 a, uint16 b, uint16 c) internal pure returns (uint16) {
    return a | b | c;
  }

  function orFlags(uint16 a, uint16 b, uint16 c, uint16 d) internal pure returns (uint16) {
    return a | b | c | d;
  }
}
