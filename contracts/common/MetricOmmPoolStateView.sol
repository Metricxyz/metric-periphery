// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title MetricOmmPoolStateView
/// @notice Off-chain friendly view helpers reading v1 pool storage via EXTSLOAD.
/// @dev Deploy one instance per factory (`constructor(factory)`). Returns raw slot and bin values as stored.
///      Factory metadata (admin, fees, pending price provider) should be read from `IMetricOmmPoolFactory` directly.
contract MetricOmmPoolStateView {
  using SafeCast for uint256;

  address internal immutable FACTORY;

  constructor(address factory) {
    FACTORY = factory;
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
    returns (uint128 totalScaledToken0InBins, uint128 totalScaledToken1InBins)
  {
    return PoolStateLibrary._slot1(pool);
  }

  function slot2(address pool)
    external
    view
    returns (uint128 notionalFeeToken0Scaled, uint128 notionalFeeToken1Scaled)
  {
    return PoolStateLibrary._slot2(pool);
  }

  function priceProvider(address pool) external view returns (address) {
    address mutableProvider = PoolStateLibrary._slot3(pool);
    if (mutableProvider != address(0)) return mutableProvider;
    return IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
  }

  function binState(address pool, int8 binIdx)
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

  function binStates(address pool, int8[] calldata binIdxs) external view returns (bytes32[] memory) {
    return PoolStateLibrary._multipleBinStates(pool, binIdxs);
  }

  function binTotalShares(address pool, int8 binIdx) external view returns (uint256) {
    return PoolStateLibrary._binTotalShares(pool, binIdx);
  }

  function binTotalShares(address pool, int8[] calldata binIdxs) external view returns (bytes32[] memory) {
    return PoolStateLibrary._multipleBinTotalShares(pool, binIdxs);
  }

  function positionBinShares(address pool, address owner, uint80 salt, int8 bin) external view returns (uint104) {
    return PoolStateLibrary._positionBinShares(pool, owner, salt, bin).toUint104();
  }

  function positionBinShares(address pool, bytes32 positionBinKey) external view returns (uint104) {
    return PoolStateLibrary._positionBinShares(pool, positionBinKey).toUint104();
  }
}
