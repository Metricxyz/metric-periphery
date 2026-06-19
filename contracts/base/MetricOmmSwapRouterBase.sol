// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmSimpleRouter} from "../interfaces/IMetricOmmSimpleRouter.sol";
import {MetricOmmSwapPath} from "../libraries/MetricOmmSwapPath.sol";
import {TransientCallbackPool} from "../libraries/TransientCallbackPool.sol";

/// @title MetricOmmSwapRouterBase
/// @notice Shared transient callback context for exact-input and exact-output routers.
abstract contract MetricOmmSwapRouterBase {
  // ============ Constants ============

  uint8 internal constant CALLBACK_MODE_JUST_PAY = 0;
  uint8 internal constant CALLBACK_MODE_EXACT_OUTPUT_ITERATE = 1;
  uint256 internal constant MAX_PATH_POOLS = MetricOmmSwapPath.MAX_PATH_POOLS;

  // ============ Internal: transient context ============

  function _setExpectedCallbackPool(address pool, uint8 callbackMode) internal {
    TransientCallbackPool.set(pool, callbackMode);
  }

  function _setExpectedCallbackPool(address pool, uint8 callbackMode, uint8 hop) internal {
    TransientCallbackPool.set(pool, callbackMode, hop);
  }

  function _expectedCallbackPool() internal view returns (address) {
    return TransientCallbackPool.getPool();
  }

  function _getCallbackMode() internal view returns (uint8) {
    return TransientCallbackPool.getCallbackMode();
  }

  function _getCallbackHop() internal view returns (uint8) {
    return TransientCallbackPool.getHop();
  }

  function _setExactOutputAmountIn(uint256 amountIn) internal {
    TransientCallbackPool.setAmountIn(amountIn);
  }

  function _getExactOutputAmountIn() internal view returns (uint256 amountIn) {
    return TransientCallbackPool.getAmountIn();
  }

  function _clearExpectedCallbackPool() internal {
    TransientCallbackPool.clear();
  }

  function _requireExpectedCallbackCaller(address caller) internal view {
    TransientCallbackPool.requireCaller(caller);
  }

  function _checkDeadline(uint256 deadline) internal view {
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > deadline) revert IMetricOmmSimpleRouter.TransactionExpired(deadline, block.timestamp);
  }
}
