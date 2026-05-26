// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {PoolSlot0, SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";

/// @title OracleValueStopLossSubhook
/// @notice Stop-loss guard that tracks per-bin value per share in both token0 and token1
///         terms using the pool's oracle price. Reverts a swap if either metric drops below its
///         high watermark by more than `maxDrawdownE6`.
/// @dev Value formulas (Q64.64 oracle mid-price = token1 per token0):
///
///      metricToken0 = token0PerShare + token1PerShare * 2^64 / midPrice   (everything in token0)
///      metricToken1 = token0PerShare * midPrice / 2^64 + token1PerShare   (everything in token1)
///
///      Both metrics are tracked independently. A swap is reverted if EITHER drops below its
///      respective high watermark by more than the configured drawdown threshold.
///
///      The pool admin is trusted to configure `maxDrawdownE6` and reset watermarks when
///      legitimate market events make old watermarks stale.
abstract contract OracleValueStopLossSubhook is SubhookUtils {
  uint256 private constant Q64 = 1 << 64;

  mapping(address pool => uint256) public oracleStopLossDrawdownE6;

  mapping(address pool => mapping(int8 binIdx => uint256)) public highWatermarkToken0;
  mapping(address pool => mapping(int8 binIdx => uint256)) public highWatermarkToken1;

  error OracleStopLossTriggered(int8 binIdx, bool isToken0, uint256 currentMetric, uint256 threshold);
  error OracleStopLossDrawdownTooLarge(uint256 requested);

  event OracleStopLossDrawdownSet(address indexed pool, uint256 newMaxDrawdownE6);
  event OracleStopLossHighWatermarkReset(address indexed pool, int8 binIdx);
  event OracleStopLossHighWatermarkUpdated(
    address indexed pool, int8 binIdx, uint256 newHwmToken0, uint256 newHwmToken1
  );

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.AFTER_SWAP_FLAG;
  }

  function setOracleStopLossDrawdown(address pool_, uint256 newMaxDrawdownE6) external {
    _onlyPoolAdmin(pool_);
    if (newMaxDrawdownE6 > 1e6) revert OracleStopLossDrawdownTooLarge(newMaxDrawdownE6);
    oracleStopLossDrawdownE6[pool_] = newMaxDrawdownE6;
    emit OracleStopLossDrawdownSet(pool_, newMaxDrawdownE6);
  }

  function resetOracleStopLossHighWatermarks(address pool_, int8 binIdx) external {
    _onlyPoolAdmin(pool_);
    highWatermarkToken0[pool_][binIdx] = 0;
    highWatermarkToken1[pool_][binIdx] = 0;
    emit OracleStopLossHighWatermarkReset(pool_, binIdx);
  }

  /// @dev Called from the composed hook's `afterSwap` override.
  function _afterSwapOracleStopLoss(
    address pool_,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    SwapOracleSnapshot calldata oracle
  ) internal {
    uint256 drawdown = oracleStopLossDrawdownE6[pool_];
    if (drawdown == 0) return;

    uint256 midPriceX64 = (uint256(oracle.bidPriceX64) + uint256(oracle.askPriceX64)) / 2;

    PoolSlot0 memory s0 = Slot0Library.unpack(packedSlot0Initial);
    PoolSlot0 memory s1 = Slot0Library.unpack(packedSlot0Final);

    int8 lo = s0.curBinIdx < s1.curBinIdx ? s0.curBinIdx : s1.curBinIdx;
    int8 hi = s0.curBinIdx > s1.curBinIdx ? s0.curBinIdx : s1.curBinIdx;

    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 count = uint256(int256(hi) - int256(lo) + 1);

    int8[] memory binIdxs = new int8[](count);
    for (uint256 i = 0; i < count; i++) {
      // forge-lint: disable-next-line(unsafe-typecast)
      binIdxs[i] = int8(int256(lo) + int256(i));
    }

    bytes32[] memory states = PoolStateLibrary._multipleBinStates(pool_, binIdxs);
    bytes32[] memory shares = PoolStateLibrary._multipleBinTotalShares(pool_, binIdxs);

    uint256 floorMultiplier = 1e6 - drawdown;

    for (uint256 i = 0; i < count; i++) {
      uint256 totalShares = PoolStateLibrary._decodeBinTotalShares(shares[i]);
      if (totalShares == 0) continue;

      (uint104 t0, uint104 t1,,,) = PoolStateLibrary._decodeBinState(states[i]);

      uint256 token0PerShareE18 = Math.mulDiv(uint256(t0), 1e18, totalShares);
      uint256 token1PerShareE18 = Math.mulDiv(uint256(t1), 1e18, totalShares);

      uint256 metricT0 = token0PerShareE18 + Math.mulDiv(token1PerShareE18, Q64, midPriceX64);
      uint256 metricT1 = Math.mulDiv(token0PerShareE18, midPriceX64, Q64) + token1PerShareE18;

      _checkAndUpdateWatermark(pool_, binIdxs[i], true, metricT0, highWatermarkToken0, floorMultiplier);
      _checkAndUpdateWatermark(pool_, binIdxs[i], false, metricT1, highWatermarkToken1, floorMultiplier);
    }
  }

  function _checkAndUpdateWatermark(
    address pool_,
    int8 binIdx,
    bool isToken0,
    uint256 metric,
    mapping(address => mapping(int8 => uint256)) storage hwmMapping,
    uint256 floorMultiplier
  ) private {
    uint256 hwm = hwmMapping[pool_][binIdx];

    if (metric >= hwm) {
      if (metric > hwm) {
        hwmMapping[pool_][binIdx] = metric;
      }
    } else {
      uint256 threshold = hwm * floorMultiplier / 1e6;
      if (metric < threshold) {
        revert OracleStopLossTriggered(binIdx, isToken0, metric, threshold);
      }
    }
  }
}
