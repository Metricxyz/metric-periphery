// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "@metric-core/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";

/// @title IMetricOmmPoolLiquidityAdder
/// @notice Periphery contract for adding liquidity with caller-funded token settlement.
/// @dev The position `owner` may differ from `msg.sender`, but token pulls in callback are always sourced from
///      `msg.sender` that initiated the add call.
interface IMetricOmmPoolLiquidityAdder is IMetricOmmModifyLiquidityCallback {
  // ============ Errors ============

  /// @notice Constructor received zero factory address.
  error InvalidPoolFactory();
  /// @notice Owner argument is zero address for owner-based add path.
  error InvalidPositionOwner();
  /// @notice `LiquidityDelta` arrays have different lengths.
  error LiquidityDeltaLengthMismatch();
  /// @notice Exact-shares path received empty liquidity delta.
  error EmptyLiquidityDelta();
  /// @notice Weighted add contains a zero weight entry.
  error ZeroWeight();
  /// @notice Scaled weighted share rounded to zero for at least one bin.
  error SharesRoundedToZero();
  /// @notice Probe call unexpectedly returned instead of reverting with `LiquidityProbe`.
  error WeightedProbeInconclusive();
  /// @notice Caught revert payload too short to decode expected probe error.
  /// @param length Raw revert payload length in bytes.
  error UnexpectedRevertLength(uint256 length);
  /// @notice Callback mode discriminator in `data` is invalid.
  error InvalidCallbackKind();
  /// @notice Callback reached adder without an active transient settlement context.
  error CallbackContextNotActive();
  /// @notice Callback caller does not match the pool in active transient context.
  /// @param caller Actual callback caller.
  /// @param expectedPool Pool currently bound in transient context.
  error InvalidCallbackCaller(address caller, address expectedPool);
  /// @notice Pay settlement context is already active (nested add attempt).
  error PayContextAlreadyActive();
  /// @notice Probe-mode callback payload carrying required token amounts.
  /// @param amount0Due Token0 amount the pool would pull.
  /// @param amount1Due Token1 amount the pool would pull.
  error LiquidityProbe(uint256 amount0Due, uint256 amount1Due);
  /// @notice Paying callback requested more tokens than caller caps allow.
  /// @param amount0Due Requested token0 amount.
  /// @param amount1Due Requested token1 amount.
  /// @param maxAmount0 Caller cap for token0.
  /// @param maxAmount1 Caller cap for token1.
  error MaxAmountExceeded(uint256 amount0Due, uint256 amount1Due, uint256 maxAmount0, uint256 maxAmount1);

  // ============ Mutating: Liquidity ============

  /// @notice Add liquidity to `owner` with explicit per-bin shares and max token caps.
  /// @param pool Target pool address.
  /// @param owner Position owner recorded in pool storage.
  /// @param salt Position salt in the owner key-space.
  /// @param deltas Shares per bin.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityExactShares(
    address pool,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1
  ) external returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity for caller-owned position with explicit shares and max token caps.
  /// @param pool Target pool address.
  /// @param salt Position salt in caller key-space.
  /// @param deltas Shares per bin.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityExactShares(
    address pool,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1
  ) external returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity from weight vector by probing and scaling to fit max caps.
  /// @param pool Target pool address.
  /// @param owner Position owner recorded in pool storage.
  /// @param salt Position salt in owner key-space.
  /// @param weightDeltas Weight vector used for probe then scaled to integer shares.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityWeighted(
    address pool,
    address owner,
    uint80 salt,
    LiquidityDelta calldata weightDeltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1
  ) external returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity from weight vector by probing and scaling to fit max caps for caller-owned position.
  /// @param pool Target pool address.
  /// @param salt Position salt in caller key-space.
  /// @param weightDeltas Weight vector used for probe then scaled to integer shares.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityWeighted(
    address pool,
    uint80 salt,
    LiquidityDelta calldata weightDeltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1
  ) external returns (uint256 amount0Added, uint256 amount1Added);
}
