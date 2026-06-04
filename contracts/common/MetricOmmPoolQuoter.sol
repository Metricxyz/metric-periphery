// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

/// @title MetricOmmPoolQuoter
/// @notice Revert-decoding quote adapter over `simulateSwapAndRevert`.
/// @dev Shared by `MetricOmmPoolSwapper` and `MetricOmmPoolDataProvider`.
contract MetricOmmPoolQuoter {
  /// @notice Wrapped downstream revert from quote simulation path.
  error WrappedError(address target, bytes4 selector, bytes reason, bytes additionalInfo);

  /// @notice Simulate swap and return pool deltas without state changes.
  /// @dev Uses `msg.sender` as `recipient` and empty `hookData`; use the overload when hooks gate on those fields.
  function quoteSwap(
    address pool,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) public virtual returns (int128 amount0Delta, int128 amount1Delta) {
    return _quoteSwap(pool, msg.sender, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, hex"");
  }

  /// @notice Simulate swap with explicit hook context (matches live `swap` hook inputs).
  function quoteSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata hookData
  ) public virtual returns (int128 amount0Delta, int128 amount1Delta) {
    return _quoteSwap(pool, recipient, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, hookData);
  }

  function _quoteSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory hookData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPool(pool)
      .simulateSwapAndRevert(
        recipient, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, hookData
      ) {
      revert("SimulateSwapAndRevert did not revert");
    } catch (bytes memory reason) {
      // forge-lint: disable-next-line(unsafe-typecast)
      if (bytes4(reason) == IMetricOmmPoolActions.SimulateSwap.selector) {
        int256 a0;
        int256 a1;
        assembly {
          a0 := mload(add(reason, 36))
          a1 := mload(add(reason, 68))
        }
        // Safe: values returned from simulateSwapAndRevert are bounded by int128.max and int128.min.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount0Delta = int128(a0);
        // forge-lint: disable-next-line(unsafe-typecast)
        amount1Delta = int128(a1);
        return (amount0Delta, amount1Delta);
      } else {
        revert WrappedError(pool, IMetricOmmPoolActions.simulateSwapAndRevert.selector, reason, "");
      }
    }
  }
}
