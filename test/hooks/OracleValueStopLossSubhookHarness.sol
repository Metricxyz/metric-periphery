// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {BaseMetricHook} from "../../contracts/hooks/base/BaseMetricHook.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
import {OracleValueStopLossSubhook} from "../../contracts/hooks/subhooks/OracleValueStopLossSubhook.sol";

contract OracleValueStopLossSubhookHarness is BaseMetricHook, OracleValueStopLossSubhook {
  constructor(address pool_, address factory_) BaseMetricHook(pool_) SubhookUtils(factory_) {}

  function _hookPool() internal view override returns (address) {
    return pool;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeAfterSwapOracleStopLoss(
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    SwapOracleSnapshot calldata oracle
  ) external {
    _afterSwapOracleStopLoss(pool, packedSlot0Initial, packedSlot0Final, oracle);
  }
}
