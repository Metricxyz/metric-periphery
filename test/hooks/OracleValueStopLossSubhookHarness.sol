// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {BaseMetricHook} from "../../contracts/hooks/base/BaseMetricHook.sol";
import {OracleValueStopLossSubhook} from "../../contracts/hooks/subhooks/OracleValueStopLossSubhook.sol";

contract OracleValueStopLossSubhookHarness is BaseMetricHook, OracleValueStopLossSubhook {
  address public testPool;

  constructor(address pool_, address factory_) BaseMetricHook(factory_) {
    testPool = pool_;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeAfterSwapOracleStopLoss(
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external {
    _afterSwapOracleStopLoss(testPool, packedSlot0Initial, packedSlot0Final, bidPriceX64, askPriceX64);
  }
}
