// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {PoolSlot0} from "@metric-core/types/HookTypes.sol";
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
///      The pool admin can configure `maxDrawdownE6` and set per-bin watermarks when
///      legitimate market events make automatic tracking stale.
abstract contract OracleValueStopLossSubhook is SubhookUtils {
  using SafeCast for uint256;

  uint256 private constant Q64 = 1 << 64;

  /// @dev Both metrics packed in one storage slot (uint128 each).
  struct BinHighWatermark {
    uint128 token0;
    uint128 token1;
  }

  mapping(address pool => uint256) public oracleStopLossDrawdownE6;

  mapping(address pool => mapping(int8 binIdx => BinHighWatermark)) internal _highWatermarks;

  error OracleStopLossTriggered(int8 binIdx, bool isToken0, uint256 currentMetric, uint256 threshold);
  error OracleStopLossDrawdownTooLarge(uint256 requested);

  event OracleStopLossDrawdownSet(address indexed pool, uint256 newMaxDrawdownE6);
  event OracleStopLossHighWatermarkUpdated(
    address indexed pool, int8 binIdx, uint128 newHwmToken0, uint128 newHwmToken1
  );

  function highWatermarkToken0(address pool, int8 binIdx) external view returns (uint256) {
    return _highWatermarks[pool][binIdx].token0;
  }

  function highWatermarkToken1(address pool, int8 binIdx) external view returns (uint256) {
    return _highWatermarks[pool][binIdx].token1;
  }

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.AFTER_SWAP_FLAG;
  }

  function setOracleStopLossDrawdown(address pool_, uint256 newMaxDrawdownE6) external {
    _onlyPoolAdmin(pool_);
    if (newMaxDrawdownE6 > 1e6) revert OracleStopLossDrawdownTooLarge(newMaxDrawdownE6);
    oracleStopLossDrawdownE6[pool_] = newMaxDrawdownE6;
    emit OracleStopLossDrawdownSet(pool_, newMaxDrawdownE6);
  }

  /// @notice Set or update per-bin high watermarks (e.g. after a market move that would false-trigger stop-loss).
  function setOracleStopLossHighWatermarks(address pool_, int8 binIdx, uint128 newHwmToken0, uint128 newHwmToken1)
    external
  {
    _onlyPoolAdmin(pool_);
    _highWatermarks[pool_][binIdx] = BinHighWatermark({token0: newHwmToken0, token1: newHwmToken1});
    emit OracleStopLossHighWatermarkUpdated(pool_, binIdx, newHwmToken0, newHwmToken1);
  }

  /// @dev Called from the composed hook's `afterSwap` override.
  function _afterSwapOracleStopLoss(
    address pool_,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) internal {
    uint256 drawdown = oracleStopLossDrawdownE6[pool_];
    if (drawdown == 0) return;

    uint256 midPriceX64 = (uint256(bidPriceX64) + uint256(askPriceX64)) / 2;

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

      _checkAndUpdateWatermarks(pool_, binIdxs[i], metricT0, metricT1, floorMultiplier);
    }
  }

  function _checkAndUpdateWatermarks(
    address pool_,
    int8 binIdx,
    uint256 metricT0,
    uint256 metricT1,
    uint256 floorMultiplier
  ) private {
    uint128 metric0 = metricT0.toUint128();
    uint128 metric1 = metricT1.toUint128();

    BinHighWatermark storage hwm = _highWatermarks[pool_][binIdx];
    uint128 hwm0 = hwm.token0;
    uint128 hwm1 = hwm.token1;

    (hwm0, hwm1) =
    (
      _applyWatermark(binIdx, true, metric0, hwm0, floorMultiplier),
      _applyWatermark(binIdx, false, metric1, hwm1, floorMultiplier)
    );

    if (hwm.token0 != hwm0 || hwm.token1 != hwm1) {
      hwm.token0 = hwm0;
      hwm.token1 = hwm1;
    }
  }

  function _applyWatermark(int8 binIdx, bool isToken0, uint128 metric, uint128 hwm, uint256 floorMultiplier)
    private
    pure
    returns (uint128 newHwm)
  {
    if (metric >= hwm) {
      return metric > hwm ? metric : hwm;
    }

    uint256 threshold = uint256(hwm) * floorMultiplier / 1e6;
    if (metric < threshold) {
      revert OracleStopLossTriggered(binIdx, isToken0, metric, threshold);
    }

    return hwm;
  }
}
