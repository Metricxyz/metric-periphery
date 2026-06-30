// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IERC20PermitAllowed
/// @notice Permit interface used by DAI and CHAI.
interface IERC20PermitAllowed {
  /// @notice Approve the spender to spend some tokens via the holder signature.
  function permit(
    address holder,
    address spender,
    uint256 nonce,
    uint256 expiry,
    bool allowed,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;
}
