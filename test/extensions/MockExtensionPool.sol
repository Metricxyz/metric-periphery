// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";

/// @dev Minimal pool stub for extension unit tests; must be registered on the factory stub via `setPoolAdmin`.
contract MockExtensionPool {
  address public immutable factory;

  constructor(address factory_) {
    factory = factory_;
  }

  function getImmutables() external view returns (PoolImmutables memory immutables) {
    immutables.factory = factory;
  }
}
