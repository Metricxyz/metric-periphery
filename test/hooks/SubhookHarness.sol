// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {BaseMetricHook} from "../../contracts/hooks/base/BaseMetricHook.sol";
import {MetricFactorySubhook} from "../../contracts/hooks/base/MetricFactorySubhook.sol";
import {SwapAllowlistSubhook} from "../../contracts/hooks/subhooks/SwapAllowlistSubhook.sol";
import {DepositAllowlistSubhook} from "../../contracts/hooks/subhooks/DepositAllowlistSubhook.sol";
import {SwapReporterSubhook} from "../../contracts/hooks/subhooks/SwapReporterSubhook.sol";

contract SwapAllowlistSubhookHarness is BaseMetricHook, SwapAllowlistSubhook {
  constructor(address pool, address factory) BaseMetricHook(pool) MetricFactorySubhook(factory) {}

  function _hookPool() internal view override returns (address) {
    return pool;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeBeforeSwapAllowlist(address sender) external view {
    _beforeSwapAllowlist(sender);
  }
}

contract DepositAllowlistSubhookHarness is BaseMetricHook, DepositAllowlistSubhook {
  constructor(address pool, address factory) BaseMetricHook(pool) MetricFactorySubhook(factory) {}

  function _hookPool() internal view override returns (address) {
    return pool;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return 0;
  }

  function exposeBeforeAddLiquidityAllowlist(address owner) external view {
    _beforeAddLiquidityAllowlist(owner);
  }
}

contract SwapReporterSubhookHarness is BaseMetricHook, SwapReporterSubhook {
  address public priceProviderOverride;

  constructor(address pool, address factory) BaseMetricHook(pool) MetricFactorySubhook(factory) {}

  function _hookPool() internal view override returns (address) {
    return pool;
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
      sender, recipient, zeroForOne, amountSpecified, priceLimitX64, packedSlot0Final, amount0Delta, amount1Delta
    );
  }
}
