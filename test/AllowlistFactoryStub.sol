// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev Minimal factory stub for extension tests: pool registry and admin lookups.
contract AllowlistFactoryStub {
  mapping(address => address) internal _poolAdmin;
  mapping(address => bool) public isPool;

  function setPoolAdmin(address pool, address admin_) external {
    _poolAdmin[pool] = admin_;
    isPool[pool] = true;
  }

  function poolAdmin(address pool) external view returns (address) {
    return _poolAdmin[pool];
  }
}
