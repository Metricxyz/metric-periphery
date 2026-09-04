// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";

/// @notice Test-only extension that blocks any swap whose `amountSpecified` magnitude exceeds a configured cap,
///         so ladder-building tests can exercise the binary-search fallback around a size-dependent extension gate.
contract CapExtension is IMetricOmmExtensions {
  error CapExceeded(uint256 magnitude, uint256 capExternal);

  uint256 public capExternal = type(uint256).max;

  function setCap(uint256 cap) external {
    capExternal = cap;
  }

  function initialize(address, bytes calldata) external pure returns (bytes4) {
    return IMetricOmmExtensions.initialize.selector;
  }

  function beforeSwap(
    address,
    address,
    bool,
    int128 amountSpecified,
    uint128,
    uint256,
    uint128,
    uint128,
    uint128,
    bytes calldata
  ) external view returns (bytes4) {
    uint256 magnitude = amountSpecified < 0 ? uint256(uint128(-amountSpecified)) : uint256(uint128(amountSpecified));
    if (magnitude > capExternal) revert CapExceeded(magnitude, capExternal);
    return IMetricOmmExtensions.beforeSwap.selector;
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
    uint128,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external pure returns (bytes4) {
    return IMetricOmmExtensions.afterSwap.selector;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterRemoveLiquidity.selector;
  }
}
