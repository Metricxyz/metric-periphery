// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "@metric-core/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {BaseMetricHook} from "../base/BaseMetricHook.sol";
import {MetricFactorySubhook} from "../base/MetricFactorySubhook.sol";
import {HookPermissions} from "../libraries/HookPermissions.sol";
import {SwapAllowlistSubhook} from "../subhooks/SwapAllowlistSubhook.sol";
import {DepositAllowlistSubhook} from "../subhooks/DepositAllowlistSubhook.sol";
import {SwapReporterSubhook} from "../subhooks/SwapReporterSubhook.sol";

/// @title StandardMetricHook
/// @notice Example composed hook: swap allowlist, deposit allowlist, and swap reporting.
contract StandardMetricHook is BaseMetricHook, SwapAllowlistSubhook, DepositAllowlistSubhook, SwapReporterSubhook {
  constructor(address pool_, address factory_) BaseMetricHook(pool_) MetricFactorySubhook(factory_) {}

  function _hookPool() internal view override returns (address) {
    return pool;
  }

  function getHookPermissions() external pure override returns (uint16) {
    return subhookPermissions();
  }

  function subhookPermissions()
    internal
    pure
    override(SwapAllowlistSubhook, DepositAllowlistSubhook, SwapReporterSubhook)
    returns (uint16)
  {
    return HookPermissions.orFlags(
      SwapAllowlistSubhook.subhookPermissions(),
      DepositAllowlistSubhook.subhookPermissions(),
      SwapReporterSubhook.subhookPermissions()
    );
  }

  function beforeSwap(
    address sender,
    address,
    bool,
    int128,
    uint128,
    uint256,
    SwapOracleSnapshot calldata,
    bytes calldata
  ) external view override onlyPool returns (bytes4) {
    _beforeSwapAllowlist(sender);
    return IMetricOmmHooks.beforeSwap.selector;
  }

  function beforeAddLiquidity(address, address owner, uint80, LiquidityDelta calldata, bytes calldata)
    external
    view
    override
    onlyPool
    returns (bytes4)
  {
    _beforeAddLiquidityAllowlist(owner);
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }

  function afterSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256,
    uint256 packedSlot0Final,
    SwapOracleSnapshot calldata,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256,
    bytes calldata
  ) external override onlyPool returns (bytes4) {
    _afterSwapReport(
      sender, recipient, zeroForOne, amountSpecified, priceLimitX64, packedSlot0Final, amount0Delta, amount1Delta
    );
    return IMetricOmmHooks.afterSwap.selector;
  }
}
