// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title MetricOmmSwapResults
/// @notice Shared swap delta result helpers for routers and quoters.
library MetricOmmSwapResults {
  /// @notice Deltas do not match expected exact-in/out shape.
  error InvalidSwapDeltas();

  function extractAmountOut(bool zeroForOne, int128 amount0Delta, int128 amount1Delta) internal pure returns (int128) {
    return zeroForOne ? -amount1Delta : -amount0Delta;
  }

  function extractAmountIn(bool zeroForOne, int128 amount0Delta, int128 amount1Delta) internal pure returns (int128) {
    return zeroForOne ? amount0Delta : amount1Delta;
  }

  function getPositiveAmount(int256 amount0Delta, int256 amount1Delta) internal pure returns (int256 amount) {
    if (amount0Delta > 0 && amount1Delta < 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      return amount0Delta;
    }
    if (amount1Delta > 0 && amount0Delta < 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      return amount1Delta;
    }
    return type(int256).min;
  }

  function extractPositiveAmount(int256 amount0Delta, int256 amount1Delta) internal pure returns (int256 amount) {
    amount = getPositiveAmount(amount0Delta, amount1Delta);
    if (amount == type(int256).min) revert InvalidSwapDeltas();
    return amount;
  }

  function hasValidExactInDeltas(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    internal
    pure
    returns (bool)
  {
    if (zeroForOne) return amount0Delta > 0 && amount1Delta < 0;
    return amount1Delta > 0 && amount0Delta < 0;
  }

  function extractAmountInAndOut(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    internal
    pure
    returns (uint256 amountIn, uint256 amountOut)
  {
    if (!hasValidExactInDeltas(zeroForOne, amount0Delta, amount1Delta)) revert InvalidSwapDeltas();
    return toUnsignedAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  function toUnsignedAmounts(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    internal
    pure
    returns (uint256 inputAmount, uint256 outputAmount)
  {
    if (zeroForOne) {
      // forge-lint: disable-next-line(unsafe-typecast)
      inputAmount = uint256(uint128(amount0Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      outputAmount = uint256(uint128(-amount1Delta));
    } else {
      // forge-lint: disable-next-line(unsafe-typecast)
      inputAmount = uint256(uint128(amount1Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      outputAmount = uint256(uint128(-amount0Delta));
    }
  }
}
