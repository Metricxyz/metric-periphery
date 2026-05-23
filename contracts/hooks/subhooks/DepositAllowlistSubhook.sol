// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {MetricFactorySubhook} from "../base/MetricFactorySubhook.sol";

/// @title DepositAllowlistSubhook
/// @notice Gates `addLiquidity` by depositor address for the bound pool.
abstract contract DepositAllowlistSubhook is MetricFactorySubhook {
  mapping(address => bool) public allowedDepositor;

  event AllowedToDepositSet(address indexed depositor, bool allowed);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG;
  }

  function setAllowedToDeposit(address depositor, bool allowed) external {
    _onlyPoolAdmin();
    allowedDepositor[depositor] = allowed;
    emit AllowedToDepositSet(depositor, allowed);
  }

  function isAllowedToDeposit(address depositor) external view returns (bool) {
    return allowedDepositor[depositor];
  }

  function _beforeAddLiquidityAllowlist(address owner) internal view {
    if (!allowedDepositor[owner]) {
      revert IMetricOmmPoolActions.NotAllowedToDeposit();
    }
  }
}
