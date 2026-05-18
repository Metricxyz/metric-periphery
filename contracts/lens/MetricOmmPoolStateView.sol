// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {PoolImmutables} from "@metric-core/types/FactoryStorage.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title MetricOmmPoolStateView
/// @notice Off-chain friendly view helpers reading v1 pool storage via EXTSLOAD.
/// @dev Deploy one instance per factory (`constructor(factory)`). Factory metadata (admin, fees,
///      pending price provider) should be read from `IMetricOmmPoolFactory` directly.
contract MetricOmmPoolStateView {
  using SafeCast for uint256;

  address internal immutable FACTORY;

  constructor(address factory) {
    FACTORY = factory;
  }

  function _scaleMultipliers(address pool)
    internal
    view
    returns (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier)
  {
    PoolImmutables memory immutables = IMetricOmmPoolFactory(FACTORY).poolImmutables(pool);
    return (immutables.token0ScaleMultiplier, immutables.token1ScaleMultiplier);
  }

  function slot0(address pool)
    external
    view
    returns (
      uint8 _pauseLevel,
      int8 _curBinIdx,
      uint104 _curPosInBin,
      int24 _curBinDistFromProvidedPrice,
      uint24 _spreadFeeE6,
      uint24 _notionalFeeE8
    )
  {
    return PoolStateLibrary._slot0(pool);
  }

  function slot1(address pool)
    external
    view
    returns (uint128 _totalScaledToken0InBins, uint128 _totalScaledToken1InBins)
  {
    (uint128 scaled0, uint128 scaled1) = PoolStateLibrary._slot1(pool);
    (uint256 scale0, uint256 scale1) = _scaleMultipliers(pool);
    return ((uint256(scaled0) / scale0).toUint128(), (uint256(scaled1) / scale1).toUint128());
  }

  function slot2(address pool)
    external
    view
    returns (uint128 notionalFeeToken0Scaled, uint128 notionalFeeToken1Scaled)
  {
    (uint128 scaled0, uint128 scaled1) = PoolStateLibrary._slot2(pool);
    (uint256 scale0, uint256 scale1) = _scaleMultipliers(pool);
    return ((uint256(scaled0) / scale0).toUint128(), (uint256(scaled1) / scale1).toUint128());
  }

  function priceProvider(address pool) external view returns (address) {
    address mutableProvider = PoolStateLibrary._slot3(pool);
    if (mutableProvider != address(0)) return mutableProvider;
    return IMetricOmmPoolFactory(FACTORY).poolImmutables(pool).immutablePriceProvider;
  }

  function binState(address pool, int8 binIdx)
    external
    view
    returns (uint104 token0Balance, uint104 token1Balance, uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
  {
    (uint104 scaled0, uint104 scaled1, uint16 len, uint16 buy, uint16 sell) = PoolStateLibrary._binState(pool, binIdx);
    (uint256 scale0, uint256 scale1) = _scaleMultipliers(pool);
    return ((uint256(scaled0) / scale0).toUint104(), (uint256(scaled1) / scale1).toUint104(), len, buy, sell);
  }

  function binStateScaled(address pool, int8 binIdx)
    external
    view
    returns (
      uint104 token0BalanceScaled,
      uint104 token1BalanceScaled,
      uint16 lengthE6,
      uint16 addFeeBuyE6,
      uint16 addFeeSellE6
    )
  {
    return PoolStateLibrary._binState(pool, binIdx);
  }

  function binTotalShares(address pool, int8 binIdx) external view returns (uint104) {
    return PoolStateLibrary._binTotalShares(pool, binIdx).toUint104();
  }

  function binStates(address pool, int8[] calldata binIdxs)
    external
    view
    returns (
      uint104[] memory token0Balances,
      uint104[] memory token1Balances,
      uint16[] memory lengthsInUnits,
      uint16[] memory addFeeBuysE6,
      uint16[] memory addFeeSellsE6,
      uint104[] memory totalShares
    )
  {
    uint256 len = binIdxs.length;
    bytes32[] memory states = PoolStateLibrary._multipleBinStates(pool, binIdxs);
    bytes32[] memory sharesRaw = PoolStateLibrary._multipleBinTotalShares(pool, binIdxs);
    token0Balances = new uint104[](len);
    token1Balances = new uint104[](len);
    lengthsInUnits = new uint16[](len);
    addFeeBuysE6 = new uint16[](len);
    addFeeSellsE6 = new uint16[](len);
    totalShares = new uint104[](len);
    (uint256 scale0, uint256 scale1) = _scaleMultipliers(pool);

    for (uint256 i = 0; i < len; i++) {
      (uint104 s0, uint104 s1, uint16 l, uint16 b, uint16 s) = PoolStateLibrary._decodeBinState(states[i]);
      token0Balances[i] = (uint256(s0) / scale0).toUint104();
      token1Balances[i] = (uint256(s1) / scale1).toUint104();
      lengthsInUnits[i] = l;
      addFeeBuysE6[i] = b;
      addFeeSellsE6[i] = s;
      totalShares[i] = PoolStateLibrary._decodeBinTotalShares(sharesRaw[i]).toUint104();
    }
  }

  /// @notice Batch read bin state in scaled (internal) units plus total shares per bin.
  function binStatesScaled(address pool, int8[] calldata binIdxs)
    external
    view
    returns (
      uint104[] memory token0BalancesScaled,
      uint104[] memory token1BalancesScaled,
      uint16[] memory lengthsInUnits,
      uint16[] memory addFeeBuysE6,
      uint16[] memory addFeeSellsE6,
      uint104[] memory totalShares
    )
  {
    uint256 len = binIdxs.length;
    bytes32[] memory states = PoolStateLibrary._multipleBinStates(pool, binIdxs);
    bytes32[] memory sharesRaw = PoolStateLibrary._multipleBinTotalShares(pool, binIdxs);
    token0BalancesScaled = new uint104[](len);
    token1BalancesScaled = new uint104[](len);
    lengthsInUnits = new uint16[](len);
    addFeeBuysE6 = new uint16[](len);
    addFeeSellsE6 = new uint16[](len);
    totalShares = new uint104[](len);

    for (uint256 i = 0; i < len; i++) {
      (uint104 s0, uint104 s1, uint16 l, uint16 b, uint16 s) = PoolStateLibrary._decodeBinState(states[i]);
      token0BalancesScaled[i] = s0;
      token1BalancesScaled[i] = s1;
      lengthsInUnits[i] = l;
      addFeeBuysE6[i] = b;
      addFeeSellsE6[i] = s;
      totalShares[i] = PoolStateLibrary._decodeBinTotalShares(sharesRaw[i]).toUint104();
    }
  }

  function positionBinShares(address pool, address owner, uint80 salt, int8 bin) external view returns (uint104) {
    return PoolStateLibrary._positionBinShares(pool, owner, salt, bin).toUint104();
  }

  function positionBinShares(address pool, bytes32 positionBinKey) external view returns (uint104) {
    return PoolStateLibrary._positionBinShares(pool, positionBinKey).toUint104();
  }
}
