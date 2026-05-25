// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";

/// @title SwapAllowlistSubhook
/// @notice Gates `swap` by swapper address, per pool.
abstract contract SwapAllowlistSubhook is SubhookUtils {
  mapping(address pool => mapping(address swapper => bool)) public allowedSwapper;

  event AllowedToSwapSet(address indexed pool, address indexed swapper, bool allowed);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_SWAP_FLAG;
  }

  function setAllowedToSwap(address pool_, address swapper, bool allowed) external {
    _onlyPoolAdmin(pool_);
    allowedSwapper[pool_][swapper] = allowed;
    emit AllowedToSwapSet(pool_, swapper, allowed);
  }

  function isAllowedToSwap(address pool_, address swapper) external view returns (bool) {
    return allowedSwapper[pool_][swapper];
  }

  function _beforeSwapAllowlist(address pool_, address sender) internal view {
    if (!allowedSwapper[pool_][sender]) {
      revert IMetricOmmPoolActions.NotAllowedToSwap();
    }
  }
}
