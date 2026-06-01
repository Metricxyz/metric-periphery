// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";

/// @title SubhookUtils
/// @notice Shared factory wiring and helpers for pool-scoped subhooks.
abstract contract SubhookUtils {
  address public immutable FACTORY;

  error OnlyPoolAdmin(address pool, address caller, address admin);

  constructor(address factory_) {
    FACTORY = factory_;
  }

  /// @notice Permission flags required by this subhook (`MetricHooks.*_FLAG`).
  function subhookPermissions() internal pure virtual returns (uint16);

  function _onlyPoolAdmin(address pool_) internal view {
    address poolAdmin = IMetricOmmPoolFactory(FACTORY).poolAdmin(pool_);
    if (msg.sender != poolAdmin) revert OnlyPoolAdmin(pool_, msg.sender, poolAdmin);
  }

  function _resolvedPriceProvider(address pool_) internal view virtual returns (address) {
    address immutablePriceProvider = IMetricOmmPool(pool_).getImmutables().immutablePriceProvider;
    if (immutablePriceProvider != address(0)) return immutablePriceProvider;
    return PoolStateLibrary._slot3(pool_);
  }
}
