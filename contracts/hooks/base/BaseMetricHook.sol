// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {SubhookUtils} from "./SubhookUtils.sol";

/// @title BaseMetricHook
/// @notice Base for pool hooks: enforces pool-only entry and default-unimplemented callbacks.
///         A single hook instance may serve any number of pools deployed from `FACTORY`.
abstract contract BaseMetricHook is IMetricOmmExtensions, SubhookUtils {
  error OnlyPool(address caller, address factory);
  error HookNotImplemented();

  modifier onlyPool() {
    if (IMetricOmmPool(msg.sender).getImmutables().factory != FACTORY) {
      revert OnlyPool(msg.sender, FACTORY);
    }
    _;
  }

  constructor(address factory_) SubhookUtils(factory_) {}

  function initialize(address, bytes calldata) external virtual onlyFactory returns (bytes4) {
    return IMetricOmmExtensions.initialize.selector;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    virtual
    onlyPool
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    virtual
    onlyPool
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    virtual
    onlyPool
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    virtual
    onlyPool
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function beforeSwap(address, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    virtual
    onlyPool
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function afterSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint256,
    uint128,
    uint128,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external virtual onlyPool returns (bytes4) {
    revert HookNotImplemented();
  }
}
