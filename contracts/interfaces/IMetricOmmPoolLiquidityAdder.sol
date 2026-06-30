// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "@metric-core/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IMulticall} from "./IMulticall.sol";
import {IPeripheryPayments} from "./IPeripheryPayments.sol";

/// @title IMetricOmmPoolLiquidityAdder
/// @notice Periphery contract for adding liquidity with caller-funded token settlement.
/// @dev The position `owner` may differ from `msg.sender`, but token pulls in callback are always sourced from
///      `msg.sender` that initiated the add call.
/// @dev Native ETH input uses the same multicall pattern as the swap router: send ETH with the add call (or
///      `multicall{value}`) when the pool's WETH leg is token0 or token1; unused ETH can be reclaimed via
///      `refundETH` in the same multicall.
/// @dev The caller is responsible for supplying a legitimate pool address and other non-malicious parameters.
///      This contract does not verify the pool against the factory; a malicious pool can request token pulls up to
///      the caller-provided max caps during callback settlement.
interface IMetricOmmPoolLiquidityAdder is IMetricOmmModifyLiquidityCallback, IMulticall, IPeripheryPayments {
  // ============ Errors ============

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
  /// @notice Pool cursor from slot0 outside caller bounds at probe time.
  /// @param curBinIdx Current bin index read from slot0.
  /// @param curPosInBin Current position in bin read from slot0.
  /// @param minimalCurBin Caller lower bound on curBinIdx.
  /// @param minimalPosition Minimum curPosInBin when curBinIdx equals minimalCurBin.
  /// @param maximalCurBin Caller upper bound on curBinIdx.
  /// @param maximalPosition Maximum curPosInBin when curBinIdx equals maximalCurBin.
  error CursorOutOfBounds(
    int8 curBinIdx,
    uint104 curPosInBin,
    int8 minimalCurBin,
    uint104 minimalPosition,
    int8 maximalCurBin,
    uint104 maximalPosition
  );

  // ============ Mutating: Liquidity ============

  /// @notice Add liquidity to `owner` with explicit per-bin shares and max token caps.
  /// @param pool Target pool address.
  /// @param owner Position owner recorded in pool storage.
  /// @param salt Position salt in the owner key-space.
  /// @param deltas Shares per bin.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityExactShares(
    address pool,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    bytes calldata extensionData
  ) external payable returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity for caller-owned position with explicit shares and max token caps.
  /// @param pool Target pool address.
  /// @param salt Position salt in caller key-space.
  /// @param deltas Shares per bin.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityExactShares(
    address pool,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    bytes calldata extensionData
  ) external payable returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity from weight vector by probing and scaling to fit max caps.
  /// @dev Deposit composition follows the pool cursor at probe time. Use cursor bounds from slot0 to fail closed
  ///      when the pool state has been moved away from the price the caller signed for.
  /// @param pool Target pool address.
  /// @param owner Position owner recorded in pool storage.
  /// @param salt Position salt in owner key-space.
  /// @param weightDeltas Weight vector used for probe then scaled to integer shares.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @param minimalCurBin Minimum allowed curBinIdx from slot0; use type(int8).min to disable lower bin bound.
  /// @param minimalPosition Minimum curPosInBin when curBinIdx equals minimalCurBin.
  /// @param maximalCurBin Maximum allowed curBinIdx from slot0; use type(int8).max to disable upper bin bound.
  /// @param maximalPosition Maximum curPosInBin when curBinIdx equals maximalCurBin; use type(uint104).max when
  ///        unconstrained at maximalCurBin.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityWeighted(
    address pool,
    address owner,
    uint80 salt,
    LiquidityDelta calldata weightDeltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    int8 minimalCurBin,
    uint104 minimalPosition,
    int8 maximalCurBin,
    uint104 maximalPosition,
    bytes calldata extensionData
  ) external payable returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Add liquidity from weight vector by probing and scaling to fit max caps for caller-owned position.
  /// @dev Deposit composition follows the pool cursor at probe time. Use cursor bounds from slot0 to fail closed
  ///      when the pool state has been moved away from the price the caller signed for.
  /// @param pool Target pool address.
  /// @param salt Position salt in caller key-space.
  /// @param weightDeltas Weight vector used for probe then scaled to integer shares.
  /// @param maxAmountToken0 Max token0 allowed to be pulled from caller.
  /// @param maxAmountToken1 Max token1 allowed to be pulled from caller.
  /// @param minimalCurBin Minimum allowed curBinIdx from slot0; use type(int8).min to disable lower bin bound.
  /// @param minimalPosition Minimum curPosInBin when curBinIdx equals minimalCurBin.
  /// @param maximalCurBin Maximum allowed curBinIdx from slot0; use type(int8).max to disable upper bin bound.
  /// @param maximalPosition Maximum curPosInBin when curBinIdx equals maximalCurBin; use type(uint104).max when
  ///        unconstrained at maximalCurBin.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Token0 added.
  /// @return amount1Added Token1 added.
  function addLiquidityWeighted(
    address pool,
    uint80 salt,
    LiquidityDelta calldata weightDeltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    int8 minimalCurBin,
    uint104 minimalPosition,
    int8 maximalCurBin,
    uint104 maximalPosition,
    bytes calldata extensionData
  ) external payable returns (uint256 amount0Added, uint256 amount1Added);
}
