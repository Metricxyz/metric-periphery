// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "@metric-core/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {BaseMetricHook} from "../base/BaseMetricHook.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";
import {SwapAllowlistSubhook} from "../subhooks/SwapAllowlistSubhook.sol";
import {DepositAllowlistSubhook} from "../subhooks/DepositAllowlistSubhook.sol";
import {PriceVelocityGuardSubhook} from "../subhooks/PriceVelocityGuardSubhook.sol";
import {SwapReporterSubhook} from "../subhooks/SwapReporterSubhook.sol";
import {OracleValueStopLossSubhook} from "../subhooks/OracleValueStopLossSubhook.sol";

/// @title FullMetricHook
/// @notice Example composed hook with all available subhooks: swap allowlist, deposit allowlist,
///         price velocity guard, swap reporting, and oracle-based dual-metric stop-loss protection.
contract FullMetricHook is
  BaseMetricHook,
  SwapAllowlistSubhook,
  DepositAllowlistSubhook,
  PriceVelocityGuardSubhook,
  SwapReporterSubhook,
  OracleValueStopLossSubhook
{
  constructor(address factory_) BaseMetricHook(factory_) {}

  function getHookPermissions() external pure override returns (uint16) {
    return subhookPermissions();
  }

  function subhookPermissions()
    internal
    pure
    override(
      SubhookUtils,
      SwapAllowlistSubhook,
      DepositAllowlistSubhook,
      PriceVelocityGuardSubhook,
      SwapReporterSubhook,
      OracleValueStopLossSubhook
    )
    returns (uint16)
  {
    return SwapAllowlistSubhook.subhookPermissions() | DepositAllowlistSubhook.subhookPermissions()
      | PriceVelocityGuardSubhook.subhookPermissions() | SwapReporterSubhook.subhookPermissions()
      | OracleValueStopLossSubhook.subhookPermissions();
  }

  // ---- Hook callbacks ----

  function beforeSwap(
    address sender,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata
  ) external override onlyPool returns (bytes4) {
    _beforeSwapAllowlist(msg.sender, sender);
    _beforeSwapPriceVelocity(msg.sender, bidPriceX64, askPriceX64);
    return IMetricOmmHooks.beforeSwap.selector;
  }

  function beforeAddLiquidity(address, address owner, uint80, LiquidityDelta calldata, bytes calldata)
    external
    view
    override
    onlyPool
    returns (bytes4)
  {
    _beforeAddLiquidityAllowlist(msg.sender, owner);
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }

  function afterSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256,
    bytes calldata
  ) external override onlyPool returns (bytes4) {
    _afterSwapReport(
      msg.sender,
      sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Final,
      amount0Delta,
      amount1Delta
    );
    _afterSwapOracleStopLoss(msg.sender, packedSlot0Initial, packedSlot0Final, bidPriceX64, askPriceX64);
    return IMetricOmmHooks.afterSwap.selector;
  }
}
