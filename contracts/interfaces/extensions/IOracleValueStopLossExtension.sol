// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IOracleValueStopLossExtension
/// @notice Per-pool oracle value stop-loss admin, read API, and timelocked parameter updates.
interface IOracleValueStopLossExtension {
  struct BinHighWatermarks {
    uint104 token0;
    uint104 token1;
    uint40 lastDecayTs;
  }

  struct PoolStopLossConfig {
    uint32 drawdownE6;
    uint64 decayPerSecondE18;
    uint40 timelock;
    bool initialized;
  }

  struct PoolStopLossSchedule {
    uint40 pendingTimelock;
    uint40 pendingTimelockExecuteAfter;
    uint32 pendingDrawdownE6;
    uint40 pendingDrawdownExecuteAfter;
    uint64 pendingDecayPerSecondE18;
    uint40 pendingDecayExecuteAfter;
  }

  struct PendingHighWatermarks {
    uint104 token0;
    uint104 token1;
    int16 binIdx;
    uint40 executeAfter;
  }

  error OracleStopLossTriggered(int16 binIdx, bool isToken0Metric, uint256 currentMetric, uint256 threshold);
  error OracleStopLossDrawdownTooLarge(uint256 requested);
  error OracleStopLossDecayTooLarge(uint256 requested);
  error OracleStopLossAlreadyInitialized(address pool);
  error OracleStopLossNotInitialized(address pool);
  error OracleStopLossNoPendingDrawdown(address pool);
  error OracleStopLossNoPendingDecay(address pool);
  error OracleStopLossNoPendingTimelock(address pool);
  error OracleStopLossNoPendingHighWatermark(address pool);
  error OracleStopLossTimelockNotElapsed(uint256 executeAfter, uint256 currentTime);
  /// @notice `block.timestamp + timelock` does not fit in `uint40` (would wrap a deadline into the past).
  error OracleStopLossTimelockOverflow(uint256 executeAfter);

  event OracleStopLossTimelockProposed(address indexed pool, uint256 proposedTimelock, uint256 executeAfter);
  event OracleStopLossTimelockSet(address indexed pool, uint256 newTimelock);
  event OracleStopLossTimelockCancelled(address indexed pool);
  event OracleStopLossDrawdownProposed(address indexed pool, uint256 proposedDrawdownE6, uint256 executeAfter);
  event OracleStopLossDrawdownSet(address indexed pool, uint256 newMaxDrawdownE6);
  event OracleStopLossDrawdownCancelled(address indexed pool);
  event OracleStopLossDecayProposed(address indexed pool, uint256 proposedDecayPerSecondE18, uint256 executeAfter);
  event OracleStopLossDecaySet(address indexed pool, uint256 newDecayPerSecondE18);
  event OracleStopLossDecayCancelled(address indexed pool);
  event OracleStopLossHighWatermarkProposed(
    address indexed pool, int16 binIdx, uint104 proposedHwmToken0, uint104 proposedHwmToken1, uint256 executeAfter
  );
  event OracleStopLossHighWatermarkUpdated(
    address indexed pool, int16 binIdx, uint104 newHwmToken0, uint104 newHwmToken1
  );
  event OracleStopLossHighWatermarkCancelled(address indexed pool);

  function initialize(address pool, bytes calldata data) external returns (bytes4);

  function currentHighWatermarks(address pool, int16 binIdx) external view returns (uint256 hwm0, uint256 hwm1);

  function proposeOracleStopLossTimelock(address pool, uint40 newTimelock) external;

  function executeOracleStopLossTimelock(address pool) external;

  function cancelOracleStopLossTimelock(address pool) external;

  function proposeOracleStopLossDrawdown(address pool, uint256 newMaxDrawdownE6) external;

  function executeOracleStopLossDrawdown(address pool) external;

  function cancelOracleStopLossDrawdown(address pool) external;

  function proposeOracleStopLossDecay(address pool, uint256 newDecayPerSecondE18) external;

  function executeOracleStopLossDecay(address pool) external;

  function cancelOracleStopLossDecay(address pool) external;

  function proposeOracleStopLossHighWatermarks(address pool, int16 binIdx, uint104 newHwmToken0, uint104 newHwmToken1)
    external;

  function executeOracleStopLossHighWatermarks(address pool) external;

  function cancelOracleStopLossHighWatermarks(address pool) external;
}
