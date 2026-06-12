// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "@metric-core/interfaces/hooks/IMetricOmmHooks.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {IDepositAllowlistHook} from "../interfaces/hooks/IDepositAllowlistHook.sol";
import {BaseMetricHook} from "./base/BaseMetricHook.sol";

/// @title DepositAllowlistHook
/// @notice Gates `addLiquidity` by depositor address, per pool.
contract DepositAllowlistHook is BaseMetricHook, IDepositAllowlistHook {
  mapping(address pool => mapping(address depositor => bool)) public allowedDepositor;

  constructor(address factory_) BaseMetricHook(factory_) {}

  function setAllowedToDeposit(address pool_, address depositor, bool allowed) external onlyPoolAdmin(pool_) {
    allowedDepositor[pool_][depositor] = allowed;
    emit AllowedToDepositSet(pool_, depositor, allowed);
  }

  function isAllowedToDeposit(address pool_, address depositor) external view returns (bool) {
    return allowedDepositor[pool_][depositor];
  }

  function beforeAddLiquidity(address, address owner, uint80, LiquidityDelta calldata, bytes calldata)
    external
    view
    override
    returns (bytes4)
  {
    if (!allowedDepositor[msg.sender][owner]) {
      revert IMetricOmmPoolActions.NotAllowedToDeposit();
    }
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }
}
