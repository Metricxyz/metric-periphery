// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
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

  // ============ Immutables ============

  IMetricOmmPoolFactory internal immutable FACTORY;

  constructor(address factory) {
    if (factory == address(0)) revert IMetricOmmSimpleRouter.InvalidFactory();
    FACTORY = IMetricOmmPoolFactory(factory);
  }

  // ============ Internal: transient context ============

  function _setNextCallbackContext(address pool, uint8 callbackMode, address payer, address tokenToPay) internal {
    _requireFactoryPool(pool);
    TransientCallbackPool.set(pool, callbackMode, payer, tokenToPay);
  }

  function _initCallbackContextforRecursiveOutput(
    address pool,
    uint8 callbackMode,
    uint8 tradesLeft,
    address payer,
    address tokenToPay
  ) internal {
    _requireFactoryPool(pool);
    TransientCallbackPool.set(pool, callbackMode, tradesLeft, payer, tokenToPay);
  }

  function _updateCallbackContextforRecursiveOutput(address pool, uint8 tradesLeft) internal {
    _requireFactoryPool(pool);
    TransientCallbackPool.update(pool, tradesLeft);
  }

  function _expectedCallbackPool() internal view returns (address) {
    return TransientCallbackPool.getPool();
  }

  function _getCallbackMode() internal view returns (uint8) {
    return TransientCallbackPool.getCallbackMode();
  }

  function _getTradesLeft() internal view returns (uint8) {
    return TransientCallbackPool.getTradesLeft();
  }

  function _setExactOutputAmountIn(uint256 amountIn) internal {
    TransientCallbackPool.setAmountIn(amountIn);
  }

  function _getExactOutputAmountIn() internal view returns (uint256 amountIn) {
    return TransientCallbackPool.getAmountIn();
  }

  function _getPayer() internal view returns (address payer) {
    return TransientCallbackPool.getPayer();
  }

  function _getTokenToPay() internal view returns (address tokenToPay) {
    return TransientCallbackPool.getTokenToPay();
  }

  function _clearExpectedCallbackPool() internal {
    TransientCallbackPool.clear();
  }

  function _requireExpectedCallbackCaller(address caller) internal view {
    TransientCallbackPool.requireCaller(caller);
    if (!FACTORY.isPool(caller)) revert IMetricOmmSimpleRouter.InvalidPool(caller);
  }

  function _requireFactoryPool(address pool) internal view {
    if (!FACTORY.isPool(pool)) revert IMetricOmmSimpleRouter.InvalidPool(pool);
  }

  function _checkDeadline(uint256 deadline) internal view {
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > deadline) revert IMetricOmmSimpleRouter.TransactionExpired(deadline, block.timestamp);
  }
}
