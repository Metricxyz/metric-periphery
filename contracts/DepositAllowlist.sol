// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IDepositAllowlistProvider} from "@metric-core/interfaces/IDepositAllowlistProvider.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IDepositAllowlist} from "./interfaces/IDepositAllowlist.sol";

/// @title DepositAllowlist
/// @notice Pool-scoped deposit allowlist managed by each pool admin (admin address is on the factory)
contract DepositAllowlist is IDepositAllowlist {
  address public immutable FACTORY;

  mapping(address => mapping(address => bool)) internal _allowedToDeposit;

  error OnlyPoolAdmin(address pool, address caller, address admin);
  event AllowedToDepositSet(address indexed pool, address indexed depositor, bool allowed);

  constructor(address factory) {
    FACTORY = factory;
  }

  /// @inheritdoc IDepositAllowlistProvider
  function isAllowedToDeposit(address depositor) external view override returns (bool) {
    return _allowedToDeposit[msg.sender][depositor];
  }

  /// @inheritdoc IDepositAllowlistProvider
  function isAllowedToDeposit(address pool, address depositor) external view override returns (bool) {
    return _allowedToDeposit[pool][depositor];
  }

  /// @inheritdoc IDepositAllowlist
  function setAllowedToDeposit(address pool, address depositor, bool allowed) external override {
    address poolAdmin = IMetricOmmPoolFactory(FACTORY).poolAdmin(pool);
    if (msg.sender != poolAdmin) revert OnlyPoolAdmin(pool, msg.sender, poolAdmin);
    _allowedToDeposit[pool][depositor] = allowed;
    emit AllowedToDepositSet(pool, depositor, allowed);
  }
}
