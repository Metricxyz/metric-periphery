// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev Minimal factory stub: periphery allowlist contracts only call `poolAdmin(pool)`.
contract AllowlistFactoryStub {
  mapping(address => address) internal _poolAdmin;

  function setPoolAdmin(address pool, address admin_) external {
    _poolAdmin[pool] = admin_;
  }

  function poolAdmin(address pool) external view returns (address) {
    return _poolAdmin[pool];
  }
}
