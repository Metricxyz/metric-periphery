// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";

/// @dev Minimal pool stub for hook unit tests; only `factory` is read by `BaseMetricHook.onlyPool`.
contract MockHookPool {
  address public immutable factory;

  constructor(address factory_) {
    factory = factory_;
  }

  function getImmutables() external view returns (PoolImmutables memory immutables) {
    immutables.factory = factory;
  }
}
