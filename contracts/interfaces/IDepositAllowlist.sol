// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IDepositAllowlistProvider} from "@metric-core/interfaces/IDepositAllowlistProvider.sol";

/// @title IDepositAllowlist
/// @notice Full API for the periphery `DepositAllowlist` implementation: pool queries plus pool-admin configuration.
interface IDepositAllowlist is IDepositAllowlistProvider {
  /// @notice Allow or deny `depositor` for deposits on `pool`. Callable only by that pool's factory admin.
  function setAllowedToDeposit(address pool, address depositor, bool allowed) external;
}
