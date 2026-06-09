// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "@metric-core/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {BaseMetricHook} from "../base/BaseMetricHook.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";
import {SwapAllowlistSubhook} from "../subhooks/SwapAllowlistSubhook.sol";
import {DepositAllowlistSubhook} from "../subhooks/DepositAllowlistSubhook.sol";

/// @title DepositAndSwapAllowlist
/// @notice Example composed hook that gates swaps and liquidity deposits by allowlisted addresses.
contract DepositAndSwapAllowlist is BaseMetricHook, SwapAllowlistSubhook, DepositAllowlistSubhook {
  constructor(address factory_) BaseMetricHook(factory_) {}

  function getHookPermissions() external pure override returns (uint16) {
    return subhookPermissions();
  }

  function subhookPermissions()
    internal
    pure
    override(SubhookUtils, SwapAllowlistSubhook, DepositAllowlistSubhook)
    returns (uint16)
  {
    return SwapAllowlistSubhook.subhookPermissions() | DepositAllowlistSubhook.subhookPermissions();
  }

  function beforeSwap(address sender, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    override
    onlyPool
    returns (bytes4)
  {
    _beforeSwapAllowlist(msg.sender, sender);
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
}
