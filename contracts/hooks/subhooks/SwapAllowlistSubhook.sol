// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {MetricFactorySubhook} from "../base/MetricFactorySubhook.sol";

/// @title SwapAllowlistSubhook
/// @notice Gates `swap` by swapper address for the bound pool.
abstract contract SwapAllowlistSubhook is MetricFactorySubhook {
  mapping(address => bool) public allowedSwapper;

  event AllowedToSwapSet(address indexed swapper, bool allowed);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_SWAP_FLAG;
  }

  function setAllowedToSwap(address swapper, bool allowed) external {
    _onlyPoolAdmin();
    allowedSwapper[swapper] = allowed;
    emit AllowedToSwapSet(swapper, allowed);
  }

  function isAllowedToSwap(address swapper) external view returns (bool) {
    return allowedSwapper[swapper];
  }

  function _beforeSwapAllowlist(address sender) internal view {
    if (!allowedSwapper[sender]) {
      revert IMetricOmmPoolActions.NotAllowedToSwap();
    }
  }
}
