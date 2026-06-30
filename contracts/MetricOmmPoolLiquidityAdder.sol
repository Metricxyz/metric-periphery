// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {IMetricOmmPoolLiquidityAdder} from "./interfaces/IMetricOmmPoolLiquidityAdder.sol";
import {IMulticall} from "./interfaces/IMulticall.sol";

/// @title MetricOmmPoolLiquidityAdder
/// @notice Routes `addLiquidity` for EOAs: the pool calls this contract in `metricOmmModifyLiquidityCallback`,
///         which pulls tokens from the user who must have approved this adder beforehand.
/// @dev Layout follows metric-core conventions:
///      constants/state, constructor, external mutators, then internal helpers.
/// @dev The caller is responsible for supplying a legitimate pool address and other non-malicious parameters.
///      This contract does not verify the pool against the factory; a malicious pool can request token pulls up to
///      the caller-provided max caps during callback settlement.
contract MetricOmmPoolLiquidityAdder is IMetricOmmPoolLiquidityAdder, PeripheryPayments {
  // ============ Constants ============

  uint256 internal constant WAD = 1e18;

  uint8 internal constant KIND_PROBE = 0;
  uint8 internal constant KIND_PAY = 1;

  uint256 private constant T_SLOT_PAY_PAYER = 0;
  uint256 private constant T_SLOT_PAY_POOL = 1;
  uint256 private constant T_SLOT_PAY_MAX0 = 2;
  uint256 private constant T_SLOT_PAY_MAX1 = 3;

  // ============ Constructor ============

  constructor(address weth) PeripheryPayments(weth) {}

  // ============ External: multicall ============

  /// @inheritdoc IMulticall
  function multicall(bytes[] calldata data) public payable override returns (bytes[] memory results) {
    results = new bytes[](data.length);
    for (uint256 i = 0; i < data.length; i++) {
      results[i] = Address.functionDelegateCall(address(this), data[i]);
    }
  }

  // ============ External: liquidity ============

  /// @notice Add liquidity with explicit per-bin shares; reverts in callback if token amounts exceed caps.
  /// @dev `msg.sender` is always the payer for token pulls in callback (stored in transient settlement context).
  /// @param owner Position owner recorded by the pool.
  /// @param maxAmountToken0 Max token0 (native units) the pool may request; inclusive check before pull.
  /// @param maxAmountToken1 Max token1 (native units) the pool may request; inclusive check before pull.
  function addLiquidityExactShares(
    address pool,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    bytes calldata extensionData
  ) external payable override returns (uint256 amount0Added, uint256 amount1Added) {
    _validateOwner(owner);
    _validateDeltas(deltas);
    return _addLiquidity(pool, owner, salt, deltas, msg.sender, maxAmountToken0, maxAmountToken1, extensionData);
  }

  /// @notice Add liquidity with explicit per-bin shares for `msg.sender`.
  function addLiquidityExactShares(
    address pool,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    bytes calldata extensionData
  ) external payable override returns (uint256 amount0Added, uint256 amount1Added) {
    _validateDeltas(deltas);
    return _addLiquidity(pool, msg.sender, salt, deltas, msg.sender, maxAmountToken0, maxAmountToken1, extensionData);
  }

  /// @notice Add liquidity from a weight vector (used as provisional shares for a probe), then rescale shares by
  ///         `min(max0/need0, max1/need1)` (missing leg treated as unconstrained) and execute the paying add.
  /// @dev The probe always reverts inside the callback with `LiquidityProbe(need0, need1)` so the pool state is
  ///      unchanged; the second call uses scaled integer shares. Deposit composition follows the pool cursor at
  ///      probe time; use slot0 cursor bounds to revert when state has been manipulated.
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
  ) external payable override returns (uint256 amount0Added, uint256 amount1Added) {
    _validateOwner(owner);
    _validateDeltas(weightDeltas);
    _validatePositiveWeights(weightDeltas);
    _validateBinAndBinPosition(pool, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);

    try IMetricOmmPoolActions(pool)
      .addLiquidity(owner, salt, weightDeltas, abi.encode(KIND_PROBE), extensionData) returns (
      uint256, uint256
    ) {
      revert WeightedProbeInconclusive();
    } catch (bytes memory reason) {
      (uint256 need0, uint256 need1) = _decodeLiquidityProbeOrBubble(reason);
      LiquidityDelta memory scaled = _scaleWeightsToShares(weightDeltas, maxAmountToken0, maxAmountToken1, need0, need1);
      return _addLiquidity(pool, owner, salt, scaled, msg.sender, maxAmountToken0, maxAmountToken1, extensionData);
    }
  }

  /// @notice Add liquidity from a weight vector (used as provisional shares for a probe), then rescale shares by
  ///         `min(max0/need0, max1/need1)` (missing leg treated as unconstrained) and execute the paying add.
  /// @dev The probe always reverts inside the callback with `LiquidityProbe(need0, need1)` so the pool state is
  ///      unchanged; the second call uses scaled integer shares. Deposit composition follows the pool cursor at
  ///      probe time; use slot0 cursor bounds to revert when state has been manipulated.
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
  ) external payable override returns (uint256 amount0Added, uint256 amount1Added) {
    _validateDeltas(weightDeltas);
    _validatePositiveWeights(weightDeltas);
    _validateBinAndBinPosition(pool, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);

    try IMetricOmmPoolActions(pool)
      .addLiquidity(msg.sender, salt, weightDeltas, abi.encode(KIND_PROBE), extensionData) returns (
      uint256, uint256
    ) {
      revert WeightedProbeInconclusive();
    } catch (bytes memory reason) {
      (uint256 need0, uint256 need1) = _decodeLiquidityProbeOrBubble(reason);
      LiquidityDelta memory scaled = _scaleWeightsToShares(weightDeltas, maxAmountToken0, maxAmountToken1, need0, need1);
      return _addLiquidity(pool, msg.sender, salt, scaled, msg.sender, maxAmountToken0, maxAmountToken1, extensionData);
    }
  }

  /// @notice Callback settlement for probe/pay modes invoked by pool during `addLiquidity`.
  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata callbackData)
    external
    override
  {
    uint8 kind = abi.decode(callbackData, (uint8));
    if (kind == KIND_PROBE) {
      revert LiquidityProbe(amount0Delta, amount1Delta);
    }
    if (kind != KIND_PAY) revert InvalidCallbackKind();

    (address expectedPool, address payer, uint256 max0, uint256 max1) = _loadPayContext();
    if (expectedPool == address(0)) revert CallbackContextNotActive();
    if (msg.sender != expectedPool) revert InvalidCallbackCaller(msg.sender, expectedPool);
    if (amount0Delta > max0 || amount1Delta > max1) {
      revert MaxAmountExceeded(amount0Delta, amount1Delta, max0, max1);
    }

    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    address token0 = imm.token0;
    address token1 = imm.token1;
    if (amount0Delta > 0) {
      pay(token0, payer, msg.sender, amount0Delta);
    }
    if (amount1Delta > 0) {
      pay(token1, payer, msg.sender, amount1Delta);
    }
    _clearPayContext();
  }

  // ============ Internal: core flow ============

  function _addLiquidity(
    address pool,
    address positionOwner,
    uint80 salt,
    LiquidityDelta memory deltas,
    address payer,
    uint256 maxAmountToken0,
    uint256 maxAmountToken1,
    bytes calldata extensionData
  ) internal returns (uint256 amount0Added, uint256 amount1Added) {
    _setPayContext(pool, payer, maxAmountToken0, maxAmountToken1);
    try IMetricOmmPoolActions(pool)
      .addLiquidity(positionOwner, salt, deltas, abi.encode(KIND_PAY), extensionData) returns (
      uint256 a0, uint256 a1
    ) {
      amount0Added = a0;
      amount1Added = a1;
      _clearPayContext();
    } catch (bytes memory reason) {
      _clearPayContext();
      assembly ("memory-safe") {
        revert(add(reason, 32), mload(reason))
      }
    }
  }

  function _decodeLiquidityProbeOrBubble(bytes memory reason) internal pure returns (uint256 need0, uint256 need1) {
    if (reason.length < 68) revert UnexpectedRevertLength(reason.length);
    bytes4 sel;
    assembly {
      sel := mload(add(reason, 32))
    }
    if (sel != LiquidityProbe.selector) {
      assembly ("memory-safe") {
        revert(add(reason, 32), mload(reason))
      }
    }
    assembly {
      need0 := mload(add(reason, 36))
      need1 := mload(add(reason, 68))
    }
  }

  function _scaleWeightsToShares(LiquidityDelta calldata w, uint256 max0, uint256 max1, uint256 need0, uint256 need1)
    internal
    pure
    returns (LiquidityDelta memory out)
  {
    uint256 scaleWad0 = need0 == 0 ? type(uint256).max : Math.mulDiv(max0, WAD, need0);
    uint256 scaleWad1 = need1 == 0 ? type(uint256).max : Math.mulDiv(max1, WAD, need1);
    uint256 scaleWad = scaleWad0 < scaleWad1 ? scaleWad0 : scaleWad1;

    uint256 n = w.binIdxs.length;
    out.binIdxs = new int256[](n);
    out.shares = new uint256[](n);
    for (uint256 i; i < n; i++) {
      out.binIdxs[i] = w.binIdxs[i];
      out.shares[i] = Math.mulDiv(w.shares[i], scaleWad, WAD);
      if (w.shares[i] != 0 && out.shares[i] == 0) revert SharesRoundedToZero();
    }
  }

  // ============ Internal: validation ============

  function _validateOwner(address owner) internal pure {
    if (owner == address(0)) revert InvalidPositionOwner();
  }

  function _validateDeltas(LiquidityDelta calldata d) internal pure {
    if (d.binIdxs.length != d.shares.length) revert LiquidityDeltaLengthMismatch();
    if (d.binIdxs.length == 0) revert EmptyLiquidityDelta();
  }

  function _validatePositiveWeights(LiquidityDelta calldata d) internal pure {
    uint256 n = d.binIdxs.length;
    for (uint256 i; i < n; i++) {
      if (d.shares[i] == 0) revert ZeroWeight();
    }
  }

  function _validateBinAndBinPosition(
    address pool,
    int8 minimalCurBin,
    uint104 minimalPosition,
    int8 maximalCurBin,
    uint104 maximalPosition
  ) internal view {
    if (minimalCurBin > maximalCurBin) {
      revert CursorOutOfBounds(0, 0, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);
    }

    (, int8 curBinIdx, uint104 curPosInBin,,,) = PoolStateLibrary._slot0(pool);

    int256 curBin = curBinIdx;
    if (curBin < minimalCurBin || curBin > maximalCurBin) {
      revert CursorOutOfBounds(curBinIdx, curPosInBin, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);
    }
    if (curBinIdx == minimalCurBin && curPosInBin < minimalPosition) {
      revert CursorOutOfBounds(curBinIdx, curPosInBin, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);
    }
    if (curBinIdx == maximalCurBin && curPosInBin > maximalPosition) {
      revert CursorOutOfBounds(curBinIdx, curPosInBin, minimalCurBin, minimalPosition, maximalCurBin, maximalPosition);
    }
  }

  // ============ Internal: transient pay context ============

  function _setPayContext(address pool, address payer, uint256 maxAmountToken0, uint256 maxAmountToken1) internal {
    if (_tloadAddress(T_SLOT_PAY_POOL) != address(0)) revert PayContextAlreadyActive();
    _tstoreAddress(T_SLOT_PAY_POOL, pool);
    _tstoreAddress(T_SLOT_PAY_PAYER, payer);
    _tstore(T_SLOT_PAY_MAX0, maxAmountToken0);
    _tstore(T_SLOT_PAY_MAX1, maxAmountToken1);
  }

  function _loadPayContext()
    internal
    view
    returns (address pool, address payer, uint256 maxAmountToken0, uint256 maxAmountToken1)
  {
    pool = _tloadAddress(T_SLOT_PAY_POOL);
    payer = _tloadAddress(T_SLOT_PAY_PAYER);
    maxAmountToken0 = _tload(T_SLOT_PAY_MAX0);
    maxAmountToken1 = _tload(T_SLOT_PAY_MAX1);
  }

  function _clearPayContext() internal {
    _tstoreAddress(T_SLOT_PAY_POOL, address(0));
    _tstoreAddress(T_SLOT_PAY_PAYER, address(0));
    _tstore(T_SLOT_PAY_MAX0, 0);
    _tstore(T_SLOT_PAY_MAX1, 0);
  }

  function _tload(uint256 slot) internal view returns (uint256 value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  function _tstore(uint256 slot, uint256 value) internal {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  function _tloadAddress(uint256 slot) internal view returns (address value) {
    uint256 raw = _tload(slot);
    // forge-lint: disable-next-line(unsafe-typecast)
    value = address(uint160(raw));
  }

  function _tstoreAddress(uint256 slot, address value) internal {
    _tstore(slot, uint256(uint160(value)));
  }
}
