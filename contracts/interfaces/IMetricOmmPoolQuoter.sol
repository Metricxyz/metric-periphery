// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolQuoter
/// @notice Quote swap deltas by invoking pool simulation and decoding the revert payload.
interface IMetricOmmPoolQuoter {
  // ============ Errors ============

  /// @notice Wrapped downstream revert from quote simulation path.
  /// @param target External contract that reverted.
  /// @param selector Selector of the function that was called.
  /// @param reason Raw revert data returned by target.
  /// @param additionalInfo Optional contextual bytes (currently empty).
  error WrappedError(address target, bytes4 selector, bytes reason, bytes additionalInfo);

  // ============ Mutating: Quote ============

  /// @notice Simulate swap and return pool deltas without state changes.
  /// @param pool Target pool address.
  /// @param zeroForOne Swap direction.
  /// @param amountSpecified Exact input when positive, exact output when negative.
  /// @param priceLimitX64 Swap price limit.
  /// @param bidPriceX64 Bid price supplied to simulation.
  /// @param askPriceX64 Ask price supplied to simulation.
  /// @return amount0Delta Pool token0 delta (positive means pool receives token0).
  /// @return amount1Delta Pool token1 delta (positive means pool receives token1).
  function quoteSwap(
    address pool,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (int128 amount0Delta, int128 amount1Delta);
}
