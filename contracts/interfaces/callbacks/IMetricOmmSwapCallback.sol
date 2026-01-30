// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Callback for swap operations
/// @notice Any contract that calls IMetricOmmPool#swap must implement this interface
interface IMetricOmmSwapCallback {
  /// @notice Called to `msg.sender` after executing a swap via IMetricOmmPool#swap.
  /// @dev In the implementation you must pay the pool tokens owed for the swap.
  /// The caller of this method must be checked to be a valid MetricOmmPool.
  /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
  /// @param token0 The token0 being swapped
  /// @param token1 The token1 being swapped
  /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool.
  ///                     If positive, the callback must send that amount of token0 to the pool.
  /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool.
  ///                     If positive, the callback must send that amount of token1 to the pool.
  /// @param data Any data passed through by the caller via the swap call
  function metricOmmSwapCallback(
    address token0,
    address token1,
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external;
}
