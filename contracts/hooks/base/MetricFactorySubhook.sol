// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {MetricSubhook} from "./MetricSubhook.sol";

/// @title MetricFactorySubhook
/// @notice Shared factory wiring for pool-scoped subhooks.
abstract contract MetricFactorySubhook is MetricSubhook {
  address public immutable FACTORY;

  error OnlyPoolAdmin(address pool, address caller, address admin);

  constructor(address factory_) {
    FACTORY = factory_;
  }

  /// @dev Implement in composed hooks that inherit `BaseMetricHook`.
  function _hookPool() internal view virtual returns (address);

  function _onlyPoolAdmin() internal view {
    address pool_ = _hookPool();
    address poolAdmin = IMetricOmmPoolFactory(FACTORY).poolAdmin(pool_);
    if (msg.sender != poolAdmin) revert OnlyPoolAdmin(pool_, msg.sender, poolAdmin);
  }

  function _resolvedPriceProvider(address pool_) internal view virtual returns (address) {
    address mutableProvider = PoolStateLibrary._slot3(pool_);
    if (mutableProvider != address(0)) return mutableProvider;
    return IMetricOmmPoolFactory(FACTORY).poolImmutables(pool_).immutablePriceProvider;
  }
}
