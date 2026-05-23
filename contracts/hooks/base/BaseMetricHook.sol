// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "@metric-core/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";

/// @title BaseMetricHook
/// @notice Base for pool hooks: enforces pool-only entry and default-unimplemented callbacks.
abstract contract BaseMetricHook is IMetricOmmHooks {
  address public immutable pool;

  error OnlyPool(address caller, address pool);
  error HookNotImplemented();

  modifier onlyPool() {
    if (msg.sender != pool) revert OnlyPool(msg.sender, pool);
    _;
  }

  constructor(address pool_) {
    pool = pool_;
  }

  /// @notice Bitmask of enabled callbacks; used by deploy scripts for `hooksPermissions`.
  function getHookPermissions() external view virtual returns (uint16);

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

  function beforeSwap(address, address, bool, int128, uint128, uint256, SwapOracleSnapshot calldata, bytes calldata)
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
    SwapOracleSnapshot calldata,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external virtual onlyPool returns (bytes4) {
    revert HookNotImplemented();
  }
}
