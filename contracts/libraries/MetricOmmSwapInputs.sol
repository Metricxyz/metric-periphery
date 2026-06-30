// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title MetricOmmSwapInputs
/// @notice Shared swap input amount casts for routers and quoters.
library MetricOmmSwapInputs {
  using SafeCast for int256;
  using SafeCast for uint256;

  uint128 internal constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  /// @notice Provided unsigned amount does not fit in int128.
  error AmountTooLarge(uint128 amount);
  /// @notice Deltas do not match expected exact-in/out shape.
  error InvalidSwapDeltas();

  function asAmountSpecifiedIn(uint128 amountIn) internal pure returns (int128 amountSpecified) {
    amountSpecified = toInt128(amountIn);
  }

  function asAmountSpecifiedOut(uint128 amountOut) internal pure returns (int128 amountSpecified) {
    amountSpecified = -toInt128(amountOut);
  }

  function toInt128(uint128 amount) internal pure returns (int128) {
    if (amount > MAX_INT128_AS_UINT128) revert AmountTooLarge(amount);
    // forge-lint: disable-next-line(unsafe-typecast)
    return int128(amount);
  }

  function toUint128(uint256 amount) internal pure returns (uint128) {
    if (amount > MAX_INT128_AS_UINT128) revert AmountTooLarge(uint128(amount));
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint128(amount);
  }

  function int128ToUint128(int128 amount) internal pure returns (uint128) {
    return int256(amount).toUint256().toUint128();
  }

  function asAmountSpecifiedFromPositive(int256 amount) internal pure returns (int128 amountSpecified) {
    if (amount <= 0) revert InvalidSwapDeltas();
    if (amount > type(int128).max) revert AmountTooLarge(uint128(uint256(amount)));
    return negInt128(amount);
  }

  function negInt128(int256 amount) internal pure returns (int128) {
    return -amount.toInt128();
  }
}
