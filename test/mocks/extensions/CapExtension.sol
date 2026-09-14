// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";

/// @notice Test-only extension with independent caps on requested amounts and actual swap output.
contract CapExtension is IMetricOmmExtensions {
  error CapExceeded(uint256 magnitude, uint256 capExternal);
  error OutputCapExceeded(uint256 amountOut, uint256 outputCapExternal);

  uint256 public capExternal = type(uint256).max;
  uint256 public outputCapExternal = type(uint256).max;

  function setCap(uint256 cap) external {
    capExternal = cap;
  }

  function setOutputCap(uint256 cap) external {
    outputCapExternal = cap;
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
    bool zeroForOne,
    int128,
    uint128,
    uint256,
    uint256,
    uint128,
    uint128,
    uint128,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256,
    bytes calldata
  ) external view returns (bytes4) {
    uint256 amountOut = uint256(-int256(zeroForOne ? amount1Delta : amount0Delta));
    if (amountOut > outputCapExternal) revert OutputCapExceeded(amountOut, outputCapExternal);
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
