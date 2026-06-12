// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";

/// @title SubhookUtils
/// @notice Shared factory wiring and helpers for pool-scoped hooks.
abstract contract SubhookUtils {
  address public immutable FACTORY;

  error OnlyPoolAdmin(address pool, address caller, address admin);
  error OnlyFactory(address caller, address factory);

  constructor(address factory_) {
    FACTORY = factory_;
  }

  modifier onlyFactory() {
    if (msg.sender != FACTORY) revert OnlyFactory(msg.sender, FACTORY);
    _;
  }

  modifier onlyPoolAdmin(address pool_) {
    address poolAdmin = IMetricOmmPoolFactory(FACTORY).poolAdmin(pool_);
    if (msg.sender != poolAdmin) revert OnlyPoolAdmin(pool_, msg.sender, poolAdmin);
    _;
  }
}
