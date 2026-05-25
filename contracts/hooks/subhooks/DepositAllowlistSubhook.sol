// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";

/// @title DepositAllowlistSubhook
/// @notice Gates `addLiquidity` by depositor address, per pool.
abstract contract DepositAllowlistSubhook is SubhookUtils {
  mapping(address pool => mapping(address depositor => bool)) public allowedDepositor;

  event AllowedToDepositSet(address indexed pool, address indexed depositor, bool allowed);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG;
  }

  function setAllowedToDeposit(address pool_, address depositor, bool allowed) external {
    _onlyPoolAdmin(pool_);
    allowedDepositor[pool_][depositor] = allowed;
    emit AllowedToDepositSet(pool_, depositor, allowed);
  }

  function isAllowedToDeposit(address pool_, address depositor) external view returns (bool) {
    return allowedDepositor[pool_][depositor];
  }

  function _beforeAddLiquidityAllowlist(address pool_, address owner) internal view {
    if (!allowedDepositor[pool_][owner]) {
      revert IMetricOmmPoolActions.NotAllowedToDeposit();
    }
  }
}
