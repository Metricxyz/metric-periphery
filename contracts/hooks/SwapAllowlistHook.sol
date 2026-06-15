// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {ISwapAllowlistHook} from "../interfaces/hooks/ISwapAllowlistHook.sol";
import {BaseMetricHook} from "./base/BaseMetricHook.sol";

/// @title SwapAllowlistHook
/// @notice Gates `swap` by swapper address, per pool.
contract SwapAllowlistHook is BaseMetricHook, ISwapAllowlistHook {
  mapping(address pool => mapping(address swapper => bool)) public allowedSwapper;

  constructor(address factory_) BaseMetricHook(factory_) {}

  function setAllowedToSwap(address pool_, address swapper, bool allowed) external onlyPoolAdmin(pool_) {
    allowedSwapper[pool_][swapper] = allowed;
    emit AllowedToSwapSet(pool_, swapper, allowed);
  }

  function isAllowedToSwap(address pool_, address swapper) external view returns (bool) {
    return allowedSwapper[pool_][swapper];
  }

  function beforeSwap(address sender, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    view
    override
    returns (bytes4)
  {
    if (!allowedSwapper[msg.sender][sender]) {
      revert IMetricOmmPoolActions.NotAllowedToSwap();
    }
    return IMetricOmmExtensions.beforeSwap.selector;
  }
}
