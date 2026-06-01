// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {BaseMetricHook} from "../../contracts/hooks/base/BaseMetricHook.sol";
import {SwapAllowlistSubhook} from "../../contracts/hooks/subhooks/SwapAllowlistSubhook.sol";
import {DepositAllowlistSubhook} from "../../contracts/hooks/subhooks/DepositAllowlistSubhook.sol";
import {SwapReporterSubhook} from "../../contracts/hooks/subhooks/SwapReporterSubhook.sol";

contract SwapAllowlistSubhookHarness is BaseMetricHook, SwapAllowlistSubhook {
  address public testPool;

  constructor(address pool_, address factory_) BaseMetricHook(factory_) {
    testPool = pool_;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeBeforeSwapAllowlist(address swapper) external view {
    _beforeSwapAllowlist(testPool, swapper);
  }
}

contract DepositAllowlistSubhookHarness is BaseMetricHook, DepositAllowlistSubhook {
  address public testPool;

  constructor(address pool_, address factory_) BaseMetricHook(factory_) {
    testPool = pool_;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeBeforeAddLiquidityAllowlist(address owner) external view {
    _beforeAddLiquidityAllowlist(testPool, owner);
  }
}

contract SwapReporterSubhookHarness is BaseMetricHook, SwapReporterSubhook {
  address public testPool;
  address public priceProviderOverride;

  constructor(address pool_, address factory_) BaseMetricHook(factory_) {
    testPool = pool_;
  }

  function setPriceProviderOverride(address priceProvider) external {
    priceProviderOverride = priceProvider;
  }

  function _resolvedPriceProvider(address) internal view override returns (address) {
    return priceProviderOverride;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeAfterSwapReport(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Final,
    int128 amount0Delta,
    int128 amount1Delta
  ) external {
    _afterSwapReport(
      testPool,
      sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Final,
      amount0Delta,
      amount1Delta
    );
  }
}
