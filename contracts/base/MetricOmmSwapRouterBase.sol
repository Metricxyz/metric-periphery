// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmSimpleRouter} from "../interfaces/IMetricOmmSimpleRouter.sol";
import {TransientCallbackPool} from "../libraries/TransientCallbackPool.sol";

/// @title MetricOmmSwapRouterBase
/// @notice Shared settlement helpers for exact-input and exact-output routers.
abstract contract MetricOmmSwapRouterBase {
  using SafeCast for int256;
  using SafeCast for uint256;

  // ============ Constants ============

  uint8 internal constant CALLBACK_MODE_JUST_PAY = 0;
  uint8 internal constant CALLBACK_MODE_EXACT_OUTPUT_ITERATE = 1;
  /// @dev Hop index in transient storage is uint8; valid hop indices are 0..type(uint8).max.
  uint256 internal constant MAX_PATH_POOLS = uint256(type(uint8).max) + 1;
  uint128 internal constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  // ============ Internal: transient context ============

  function _setExpectedCallbackPool(address pool, uint8 callbackMode) internal {
    TransientCallbackPool.set(pool, callbackMode);
  }

  function _setExpectedCallbackPool(address pool, uint8 callbackMode, uint8 hop) internal {
    TransientCallbackPool.set(pool, callbackMode, hop);
  }

  function _expectedCallbackPool() internal view returns (address) {
    return TransientCallbackPool.getPool();
  }

  function _getCallbackMode() internal view returns (uint8) {
    return TransientCallbackPool.getCallbackMode();
  }

  function _getCallbackHop() internal view returns (uint8) {
    return TransientCallbackPool.getHop();
  }

  function _setExactOutputAmountIn(uint256 amountIn) internal {
    TransientCallbackPool.setAmountIn(amountIn);
  }

  function _getExactOutputAmountIn() internal view returns (uint256 amountIn) {
    return TransientCallbackPool.getAmountIn();
  }

  function _clearExpectedCallbackPool() internal {
    TransientCallbackPool.clear();
  }

  function _requireExpectedCallbackCaller(address caller) internal view {
    TransientCallbackPool.requireCaller(caller);
  }

  function _getPositiveAmount(int256 amount0Delta, int256 amount1Delta) internal pure returns (int256 amount) {
    if (amount0Delta > 0 && amount1Delta < 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      return amount0Delta;
    }
    if (amount1Delta > 0 && amount0Delta < 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      return amount1Delta;
    }
    revert IMetricOmmSimpleRouter.InvalidSwapDeltas();
  }

  function _openLimit(bool zeroForOne) internal pure returns (uint128) {
    return zeroForOne ? 0 : type(uint128).max;
  }

  function _validatePriceLimit(bool zeroForOne, uint128 priceLimitX64) internal pure {
    if (zeroForOne) {
      if (priceLimitX64 == type(uint128).max) {
        revert IMetricOmmSimpleRouter.InvalidPriceLimitForDirection(true, priceLimitX64);
      }
      return;
    }
    if (priceLimitX64 == 0) revert IMetricOmmSimpleRouter.InvalidPriceLimitForDirection(false, priceLimitX64);
  }

  function _checkDeadline(uint256 deadline) internal view {
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > deadline) revert IMetricOmmSimpleRouter.TransactionExpired(deadline, block.timestamp);
  }

  function _resolveZeroForOneBitmap(uint256 bitMap, uint256 hop) internal pure returns (bool zeroForOne) {
    return (bitMap >> hop) & 1 == 1;
  }

  function _amountOut(bool zeroForOne, int128 amount0Delta, int128 amount1Delta) internal pure returns (int128) {
    return zeroForOne ? -amount1Delta : -amount0Delta;
  }

  function _amountIn(bool zeroForOne, int128 amount0Delta, int128 amount1Delta) internal pure returns (int128) {
    return zeroForOne ? amount0Delta : amount1Delta;
  }

  function _toSignedExactInput(uint128 amountIn) internal pure returns (int128 amountSpecified) {
    return _int128ExactAmount(amountIn);
  }

  function _toSignedExactOutput(uint128 amountOut) internal pure returns (int128 amountSpecified) {
    return -_int128ExactAmount(amountOut);
  }

  function _int128ExactAmount(uint128 amount) internal pure returns (int128) {
    if (amount > MAX_INT128_AS_UINT128) revert IMetricOmmSimpleRouter.AmountTooLarge(amount);
    return int128(amount);
  }

  function _toUint128(int128 amount) internal pure returns (uint128) {
    return int256(amount).toUint256().toUint128();
  }

  function _negInt128(int256 amount) internal pure returns (int128) {
    if (amount <= 0) revert IMetricOmmSimpleRouter.InvalidSwapDeltas();
    if (amount > type(int128).max) {
      revert IMetricOmmSimpleRouter.AmountTooLarge(uint128(uint256(amount)));
    }
    return -amount.toInt128();
  }
}
