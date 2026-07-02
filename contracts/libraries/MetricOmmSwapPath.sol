// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";

/// @title MetricOmmSwapPath
/// @notice Shared multihop path and swap parameter helpers for routers and quoters.
library MetricOmmSwapPath {
  /// @dev tradesLeft in transient storage is uint8;
  uint256 internal constant MAX_PATH_POOLS = uint256(type(uint8).max) + 1;

  /// @notice Price-limit sentinel is invalid for swap direction.
  error InvalidPriceLimitForDirection(bool zeroForOne, uint128 priceLimitX64);

  /// @dev Maps the opposite-direction open sentinel to the canonical per-direction open limit.
  function normalizePriceLimit(bool zeroForOne, uint128 priceLimitX64) internal pure returns (uint128) {
    if (zeroForOne) {
      if (priceLimitX64 == type(uint128).max) return 0;
      return priceLimitX64;
    }
    if (priceLimitX64 == 0) return type(uint128).max;
    return priceLimitX64;
  }

  function openLimit(bool zeroForOne) internal pure returns (uint128) {
    return zeroForOne ? 0 : type(uint128).max;
  }

  function resolveZeroForOneBitmap(uint256 bitMap, uint256 hop) internal pure returns (bool zeroForOne) {
    return (bitMap >> hop) & 1 == 1;
  }

  function hopInputToken(address pool, bool zeroForOne) internal view returns (address) {
    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    return zeroForOne ? imm.token0 : imm.token1;
  }

  function hopOutputToken(address pool, bool zeroForOne) internal view returns (address) {
    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    return zeroForOne ? imm.token1 : imm.token0;
  }

  function poolsAreConnected(address[] calldata pools, uint256 zeroForOneBitMap) internal view returns (bool) {
    uint256 last = pools.length - 1;
    for (uint256 i = 0; i < last; i++) {
      bool zeroForOne = resolveZeroForOneBitmap(zeroForOneBitMap, i);
      bool nextZeroForOne = resolveZeroForOneBitmap(zeroForOneBitMap, i + 1);
      if (hopOutputToken(pools[i], zeroForOne) != hopInputToken(pools[i + 1], nextZeroForOne)) {
        return false;
      }
    }
    return true;
  }
}
