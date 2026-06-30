// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Extsload} from "@metric-core/Extsload.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {BaseMetricExtension} from "../../contracts/extensions/base/BaseMetricExtension.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";

contract MockExtensionExtsloadPool is Extsload {
  address public immutable factory;
  uint256 public immutable minimalMintableLiquidity;

  constructor(address factory_, uint256 minimalMintableLiquidity_) {
    factory = factory_;
    minimalMintableLiquidity = minimalMintableLiquidity_;
  }

  function getImmutables() external view returns (PoolImmutables memory immutables) {
    immutables.factory = factory;
    immutables.minimalMintableLiquidity = minimalMintableLiquidity;
  }
}

contract OracleValueStopLossSubExtensionTest is Test {
  uint256 private constant Q64 = 1 << 64;
  uint256 private constant E6 = 1e6;
  uint256 private constant E8 = 1e8;
  uint256 private constant MIN_SHARES = 1000;
  uint256 private constant METRIC_SCALE = 1e6;
  uint256 private constant BIN_SHARES = 10_000;

  AllowlistFactoryStub factoryStub;
  OracleValueStopLossExtension extension;
  MockExtensionExtsloadPool mockPool;

  address admin = makeAddr("admin");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    mockPool = new MockExtensionExtsloadPool(address(factoryStub), MIN_SHARES);
    factoryStub.setPoolAdmin(address(mockPool), admin);
    extension = new OracleValueStopLossExtension(address(factoryStub));
    _initPool(address(mockPool), 0, 0, 0);
  }

  // ---- helpers ----

  function _initPool(address pool, uint32 drawdownE6, uint32 decayE8, uint32 timelock) internal {
    vm.prank(address(factoryStub));
    extension.initialize(pool, abi.encode(drawdownE6, decayE8, timelock));
  }

  function _proposeAndExecuteTimelock(uint32 timelock) internal {
    extension.proposeOracleStopLossTimelock(address(mockPool), timelock);
    extension.executeOracleStopLossTimelock(address(mockPool));
  }

  function _packBinState(uint104 t0, uint104 t1) internal pure returns (bytes32) {
    uint256 packed = uint256(t0);
    packed |= uint256(t1) << 104;
    packed |= uint256(10_000) << 208; // lengthE6
    return bytes32(packed);
  }

  function _binStateSlot(int8 binIdx) internal pure returns (bytes32 slot) {
    uint256 baseSlot = PoolStateLibrary.MAPPING_BIN_STATES;
    assembly {
      mstore(0x00, binIdx)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _binTotalSharesSlot(int8 binIdx) internal pure returns (bytes32 slot) {
    uint256 baseSlot = PoolStateLibrary.MAPPING_BIN_TOTAL_SHARES;
    assembly {
      mstore(0x00, binIdx)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _storeBin(int8 binIdx, uint104 t0, uint104 t1, uint256 totalShares) internal {
    vm.store(address(mockPool), _binStateSlot(binIdx), _packBinState(t0, t1));
    vm.store(address(mockPool), _binTotalSharesSlot(binIdx), bytes32(totalShares));
  }

  function _packSlot0(int8 binIdx) internal pure returns (uint256) {
    return Slot0Library.pack(0, binIdx, 0, 0, 0, 0);
  }

  function _exposeStopLoss(int8 loBin, int8 hiBin, uint128 priceX64, bool zeroForOne) internal {
    vm.prank(address(mockPool));
    extension.afterSwap(
      address(0), address(0), zeroForOne, 0, 0, _packSlot0(loBin), _packSlot0(hiBin), priceX64, priceX64, 0, 0, 0, ""
    );
  }

  function _effectiveShares(uint256 shares) internal pure returns (uint256) {
    return shares < MIN_SHARES ? MIN_SHARES : shares;
  }

  function _computeMetricToken0(uint104 t0, uint104 t1, uint256 shares, uint128 midX64)
    internal
    pure
    returns (uint256)
  {
    uint256 eff = _effectiveShares(shares);
    uint256 t0ps = Math.mulDiv(uint256(t0), METRIC_SCALE, eff);
    return t0ps + Math.mulDiv(Math.mulDiv(uint256(t1), Q64, midX64), METRIC_SCALE, eff);
  }

  function _computeMetricToken1(uint104 t0, uint104 t1, uint256 shares, uint128 midX64)
    internal
    pure
    returns (uint256)
  {
    uint256 eff = _effectiveShares(shares);
    uint256 t1ps = Math.mulDiv(uint256(t1), METRIC_SCALE, eff);
    return Math.mulDiv(Math.mulDiv(uint256(t0), midX64, Q64), METRIC_SCALE, eff) + t1ps;
  }

  function _proposeAndExecuteDrawdown(uint256 drawdownE6) internal {
    extension.proposeOracleStopLossDrawdown(address(mockPool), drawdownE6);
    extension.executeOracleStopLossDrawdown(address(mockPool));
  }

  function _proposeAndExecuteDecay(uint256 decayE8) internal {
    extension.proposeOracleStopLossDecay(address(mockPool), decayE8);
    extension.executeOracleStopLossDecay(address(mockPool));
  }

  function _proposeAndExecuteWatermarks(int8 binIdx, uint104 t0, uint104 t1) internal {
    extension.proposeOracleStopLossHighWatermarks(address(mockPool), binIdx, t0, t1);
    extension.executeOracleStopLossHighWatermarks(address(mockPool));
  }

  function _drawdown() internal view returns (uint256 v) {
    (v,,,) = extension.oracleStopLossConfig(address(mockPool));
  }

  function _decay() internal view returns (uint256 v) {
    (, v,,) = extension.oracleStopLossConfig(address(mockPool));
  }

  function _configure(uint256 drawdownE6, uint256 decayE8) internal {
    vm.startPrank(admin);
    _proposeAndExecuteDrawdown(drawdownE6);
    if (decayE8 > 0) _proposeAndExecuteDecay(decayE8);
    vm.stopPrank();
  }

  // ---- admin tests ----

  function test_onlyAdminCanSetDrawdown() public {
    vm.startPrank(admin);
    _proposeAndExecuteDrawdown(50_000);
    vm.stopPrank();
    assertEq(_drawdown(), 50_000);

    address rando = makeAddr("rando");
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(mockPool), rando, admin));
    extension.proposeOracleStopLossDrawdown(address(mockPool), 100_000);
  }

  function test_drawdownCannotExceed1e6() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IOracleValueStopLossExtension.OracleStopLossDrawdownTooLarge.selector, E6 + 1)
    );
    extension.proposeOracleStopLossDrawdown(address(mockPool), E6 + 1);
  }

  function test_decayCannotExceed1e8() public {
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IOracleValueStopLossExtension.OracleStopLossDecayTooLarge.selector, E8 + 1));
    extension.proposeOracleStopLossDecay(address(mockPool), E8 + 1);
  }

  function test_initialize_setsConfig() public {
    OracleValueStopLossExtension freshExtension = new OracleValueStopLossExtension(address(factoryStub));
    MockExtensionExtsloadPool freshPool = new MockExtensionExtsloadPool(address(factoryStub), MIN_SHARES);
    vm.prank(address(factoryStub));
    freshExtension.initialize(address(freshPool), abi.encode(uint32(50_000), uint32(58), uint32(3 days)));
    (uint32 dd, uint32 decay, uint32 tl, bool initialized) = freshExtension.oracleStopLossConfig(address(freshPool));
    assertEq(dd, 50_000);
    assertEq(decay, 58);
    assertEq(tl, 3 days);
    assertTrue(initialized);
  }

  function test_cannotReinitialize() public {
    vm.prank(address(factoryStub));
    vm.expectRevert(
      abi.encodeWithSelector(IOracleValueStopLossExtension.OracleStopLossAlreadyInitialized.selector, address(mockPool))
    );
    extension.initialize(address(mockPool), abi.encode(uint32(0), uint32(0), uint32(0)));
  }

  function test_timelockUpdateDelayedByCurrentTimelock() public {
    OracleValueStopLossExtension freshExtension = new OracleValueStopLossExtension(address(factoryStub));
    MockExtensionExtsloadPool freshPool = new MockExtensionExtsloadPool(address(factoryStub), MIN_SHARES);
    factoryStub.setPoolAdmin(address(freshPool), admin);
    vm.prank(address(factoryStub));
    freshExtension.initialize(address(freshPool), abi.encode(uint32(0), uint32(0), uint32(1 days)));

    vm.startPrank(admin);
    freshExtension.proposeOracleStopLossTimelock(address(freshPool), uint32(2 days));
    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTimelockNotElapsed.selector,
        block.timestamp + 1 days,
        block.timestamp
      )
    );
    freshExtension.executeOracleStopLossTimelock(address(freshPool));
    vm.warp(block.timestamp + 1 days);
    freshExtension.executeOracleStopLossTimelock(address(freshPool));
    vm.stopPrank();
    (,, uint32 tl,) = freshExtension.oracleStopLossConfig(address(freshPool));
    assertEq(tl, 2 days);
  }

  function test_drawdownTimelockDelaysExecution() public {
    vm.startPrank(admin);
    _proposeAndExecuteTimelock(uint32(1 days));
    extension.proposeOracleStopLossDrawdown(address(mockPool), 50_000);
    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTimelockNotElapsed.selector,
        block.timestamp + 1 days,
        block.timestamp
      )
    );
    extension.executeOracleStopLossDrawdown(address(mockPool));
    vm.warp(block.timestamp + 1 days);
    extension.executeOracleStopLossDrawdown(address(mockPool));
    vm.stopPrank();
    assertEq(_drawdown(), 50_000);
  }

  function test_decayTimelockZeroExecutesImmediately() public {
    vm.startPrank(admin);
    extension.proposeOracleStopLossDecay(address(mockPool), 58);
    extension.executeOracleStopLossDecay(address(mockPool));
    vm.stopPrank();
    assertEq(_decay(), 58);
  }

  function test_cancelPendingDrawdown() public {
    vm.startPrank(admin);
    _proposeAndExecuteTimelock(uint32(1 days));
    extension.proposeOracleStopLossDrawdown(address(mockPool), 50_000);
    extension.cancelOracleStopLossDrawdown(address(mockPool));
    vm.expectRevert(
      abi.encodeWithSelector(IOracleValueStopLossExtension.OracleStopLossNoPendingDrawdown.selector, address(mockPool))
    );
    extension.executeOracleStopLossDrawdown(address(mockPool));
    vm.stopPrank();
  }

  function test_onlyAdminCanSetWatermarks() public {
    vm.startPrank(admin);
    _proposeAndExecuteWatermarks(0, 1, 2);
    vm.stopPrank();

    address rando = makeAddr("rando");
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(mockPool), rando, admin));
    extension.proposeOracleStopLossHighWatermarks(address(mockPool), 0, 1, 2);
  }

  function test_watermarkTimelockDelaysExecution() public {
    vm.startPrank(admin);
    _proposeAndExecuteTimelock(uint32(1 days));
    extension.proposeOracleStopLossHighWatermarks(address(mockPool), 0, 11, 22);
    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTimelockNotElapsed.selector,
        block.timestamp + 1 days,
        block.timestamp
      )
    );
    extension.executeOracleStopLossHighWatermarks(address(mockPool));
    vm.warp(block.timestamp + 1 days);
    extension.executeOracleStopLossHighWatermarks(address(mockPool));
    vm.stopPrank();

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0, 11);
    assertEq(hwm1, 22);
  }

  function test_cancelPendingWatermarks() public {
    vm.startPrank(admin);
    extension.proposeOracleStopLossHighWatermarks(address(mockPool), 0, 1, 2);
    extension.cancelOracleStopLossHighWatermarks(address(mockPool));
    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossNoPendingHighWatermark.selector, address(mockPool)
      )
    );
    extension.executeOracleStopLossHighWatermarks(address(mockPool));
    vm.stopPrank();
  }

  // ---- no-op when drawdown is zero ----

  function test_noOpWhenDrawdownNotConfigured() public {
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _exposeStopLoss(0, 0, uint128(Q64), false);
  }

  // ---- sets both watermarks on first swap ----

  function test_setsBothWatermarksOnFirstSwap() public {
    uint104 t0 = 500;
    uint104 t1 = 500;
    uint256 shares = BIN_SHARES;
    uint128 price = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, price, false);

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0, _computeMetricToken0(t0, t1, shares, price));
    assertEq(hwm1, _computeMetricToken1(t0, t1, shares, price));
  }

  // ---- 1. direction mapping ----

  function test_metricT0BreachBlocksZeroForOneOnly() public {
    uint104 t0 = 1000;
    uint104 t1 = 1000;
    uint256 shares = BIN_SHARES;
    uint128 initPrice = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, initPrice, false);

    // Mid rises → metricT0 drops, metricT1 rises (pure mid move).
    uint128 highPrice = uint128(2 * Q64);

    uint256 m0 = _computeMetricToken0(t0, t1, shares, highPrice);
    (uint256 hwm0,) = extension.currentHighWatermarks(address(mockPool), 0);
    uint256 threshold = hwm0 * (E6 - 50_000) / E6;

    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTriggered.selector, int8(0), true, m0, threshold
      )
    );
    _exposeStopLoss(0, 0, highPrice, true);

    // Opposite direction allowed.
    _exposeStopLoss(0, 0, highPrice, false);
  }

  function test_metricT1BreachBlocksOneForZeroOnly() public {
    uint104 t0 = 1000;
    uint104 t1 = 1000;
    uint256 shares = BIN_SHARES;
    uint128 initPrice = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, initPrice, false);

    // Mid falls → metricT1 drops, metricT0 rises.
    uint128 lowPrice = uint128(Q64 / 2);

    uint256 m1 = _computeMetricToken1(t0, t1, shares, lowPrice);
    (, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    uint256 threshold = hwm1 * (E6 - 50_000) / E6;

    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTriggered.selector, int8(0), false, m1, threshold
      )
    );
    _exposeStopLoss(0, 0, lowPrice, false);

    // Opposite direction allowed.
    _exposeStopLoss(0, 0, lowPrice, true);
  }

  function test_bothBreachedBlocksBothDirections() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, price, false);

    // Value leak: both metrics drop.
    _storeBin(0, 800, 800, BIN_SHARES);

    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);

    vm.expectRevert();
    _exposeStopLoss(0, 0, price, false);
  }

  // ---- 2. auto-reopen on mid mean-reversion ----

  function test_autoReopenOnMidMeanReversion() public {
    uint104 t0 = 1000;
    uint104 t1 = 1000;
    uint256 shares = BIN_SHARES;
    uint128 initPrice = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, initPrice, false);

    uint128 highPrice = uint128(2 * Q64);
    vm.expectRevert();
    _exposeStopLoss(0, 0, highPrice, true);

    // Mid reverts to initial — metricT0 recovers within band.
    _exposeStopLoss(0, 0, initPrice, true);
  }

  // ---- 3. decay re-arm ----

  function test_decayRearmsAfterPermanentRepricing() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, 58); // ~5%/day

    _exposeStopLoss(0, 0, price, false);

    _storeBin(0, 800, 800, BIN_SHARES);

    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);

    // Warp until decayed watermark ratchets below the drawdown floor (~4 days at 58 E8/s).
    vm.warp(block.timestamp + 5 days);

    _exposeStopLoss(0, 0, price, true);

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    uint256 cur0 = _computeMetricToken0(800, 800, BIN_SHARES, price);
    uint256 cur1 = _computeMetricToken1(800, 800, BIN_SHARES, price);
    assertGe(hwm0, cur0);
    assertGe(hwm1, cur1);
  }

  // ---- 4. V-shape move ----

  function test_vShapeMove_blocksEachSideThenDecays() public {
    uint104 t0 = 1000;
    uint104 t1 = 1000;
    uint256 shares = BIN_SHARES;
    uint128 initPrice = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 58);

    _exposeStopLoss(0, 0, initPrice, false);

    // Leg 1: mid spikes — blocks zeroForOne.
    uint128 highPrice = uint128(2 * Q64);
    vm.expectRevert();
    _exposeStopLoss(0, 0, highPrice, true);
    _exposeStopLoss(0, 0, highPrice, false);

    // Leg 2: mid crashes — blocks oneForZero.
    uint128 lowPrice = uint128(Q64 / 2);
    vm.expectRevert();
    _exposeStopLoss(0, 0, lowPrice, false);
    _exposeStopLoss(0, 0, lowPrice, true);

    // Decay unwinds the first block (high-price leg).
    vm.warp(block.timestamp + 2 days);
    _exposeStopLoss(0, 0, lowPrice, true);
  }

  // ---- 5. dust shares saturate ----

  function test_dustShares_flooredByMinLiquidity_noRevert() public {
    // Dust shares are floored at minimalMintableLiquidity; max uint104 balances clamp to uint104.max.
    _storeBin(0, type(uint104).max, type(uint104).max, 1);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, uint128(Q64), false);

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0, type(uint104).max);
    assertEq(hwm1, type(uint104).max);
  }

  // ---- 6. first touch with decay enabled ----

  function test_firstTouchWithDecayEnabled_initializesToCurrentMetric() public {
    uint104 t0 = 500;
    uint104 t1 = 500;
    uint256 shares = BIN_SHARES;
    uint128 price = uint128(Q64);

    _storeBin(0, t0, t1, shares);
    _configure(50_000, 58);

    _exposeStopLoss(0, 0, price, false);

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0, _computeMetricToken0(t0, t1, shares, price));
    assertEq(hwm1, _computeMetricToken1(t0, t1, shares, price));
  }

  // ---- 7. dt * rate >= 1e8 floors at 0, ratchet restores ----

  function test_decayFloorsAtZero_ratchetRestores() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, E8); // 100%/second

    _exposeStopLoss(0, 0, price, false);

    vm.warp(block.timestamp + 2);

    (uint256 hwm0Before,) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0Before, 0);

    _exposeStopLoss(0, 0, price, false);

    (uint256 hwm0After,) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0After, _computeMetricToken0(1000, 1000, BIN_SHARES, price));
  }

  // ---- 8. two-sided breach with decay ----

  function test_twoSidedBreach_decayRearms_renewedExtractionRetriggers() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, 58);

    _exposeStopLoss(0, 0, price, false);

    _storeBin(0, 800, 800, BIN_SHARES);

    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);
    vm.expectRevert();
    _exposeStopLoss(0, 0, price, false);

    vm.warp(block.timestamp + 5 days);
    _exposeStopLoss(0, 0, price, true);

    // Renewed extraction immediately re-triggers.
    _storeBin(0, 700, 700, BIN_SHARES);
    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);
  }

  function test_setDecayZero_freezesRecovery() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, 58);

    _exposeStopLoss(0, 0, price, false);
    _storeBin(0, 800, 800, BIN_SHARES);

    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);

    vm.warp(block.timestamp + 30 days);

    vm.startPrank(admin);
    _proposeAndExecuteDecay(0);
    vm.stopPrank();

    // Still blocked — decay frozen.
    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);
  }

  // ---- existing coverage (updated) ----

  function test_smallDrawdownPasses() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(100_000, 0);

    _exposeStopLoss(0, 0, price, false);
    _storeBin(0, 950, 950, BIN_SHARES);
    _exposeStopLoss(0, 0, price, false);
  }

  function test_multiBin_checksAllTouchedBins() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _storeBin(1, 1000, 1000, BIN_SHARES);
    _configure(50_000, 0);

    _exposeStopLoss(0, 1, price, false);

    uint256 expectedT0 = _computeMetricToken0(1000, 1000, BIN_SHARES, price);
    (uint256 hwm0Bin0,) = extension.currentHighWatermarks(address(mockPool), 0);
    (uint256 hwm0Bin1,) = extension.currentHighWatermarks(address(mockPool), 1);
    assertEq(hwm0Bin0, expectedT0);
    assertEq(hwm0Bin1, expectedT0);
  }

  function test_watermarksUpdateOnIncrease() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 500, 500, BIN_SHARES);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, price, false);
    (uint256 hwm0Before, uint256 hwm1Before) = extension.currentHighWatermarks(address(mockPool), 0);

    _storeBin(0, 600, 600, BIN_SHARES);
    _exposeStopLoss(0, 0, price, false);

    (uint256 hwm0After, uint256 hwm1After) = extension.currentHighWatermarks(address(mockPool), 0);
    assertGt(hwm0After, hwm0Before);
    assertGt(hwm1After, hwm1Before);
  }

  function test_adminSetAllowsRecovery() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(50_000, 0);

    _exposeStopLoss(0, 0, price, false);

    _storeBin(0, 800, 800, BIN_SHARES);
    vm.expectRevert();
    _exposeStopLoss(0, 0, price, true);

    uint104 expectedT0 = uint104(_computeMetricToken0(800, 800, BIN_SHARES, price));
    uint104 expectedT1 = uint104(_computeMetricToken1(800, 800, BIN_SHARES, price));
    vm.startPrank(admin);
    _proposeAndExecuteWatermarks(0, expectedT0, expectedT1);
    vm.stopPrank();

    _exposeStopLoss(0, 0, price, true);

    (uint256 hwm0, uint256 hwm1) = extension.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwm0, expectedT0);
    assertEq(hwm1, expectedT1);
  }

  function test_skipsEmptyBins() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _storeBin(1, 0, 0, 0);
    _storeBin(2, 1000, 1000, BIN_SHARES);
    _configure(50_000, 0);

    _exposeStopLoss(0, 2, price, false);

    (uint256 hwm0,) = extension.currentHighWatermarks(address(mockPool), 0);
    (uint256 hwm1,) = extension.currentHighWatermarks(address(mockPool), 1);
    (uint256 hwm2,) = extension.currentHighWatermarks(address(mockPool), 2);
    assertGt(hwm0, 0);
    assertEq(hwm1, 0);
    assertGt(hwm2, 0);
  }

  function test_differentOraclePricesProduceDifferentMetrics() public {
    _storeBin(0, 1000, 500, BIN_SHARES);
    _configure(50_000, 0);

    uint128 price1 = uint128(Q64);
    _exposeStopLoss(0, 0, price1, false);
    (uint256 hwmT0_price1,) = extension.currentHighWatermarks(address(mockPool), 0);

    vm.startPrank(admin);
    _proposeAndExecuteWatermarks(0, 0, 0);
    vm.stopPrank();

    uint128 price2 = uint128(2 * Q64);
    _exposeStopLoss(0, 0, price2, false);
    (uint256 hwmT0_price2,) = extension.currentHighWatermarks(address(mockPool), 0);

    assertGt(hwmT0_price1, hwmT0_price2);
  }

  function test_exactBoundaryPasses() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, BIN_SHARES);
    _configure(100_000, 0);

    _exposeStopLoss(0, 0, price, false);

    // Value leak exactly at 10% boundary — both metrics at threshold, no revert.
    _storeBin(0, 900, 900, BIN_SHARES);
    _exposeStopLoss(0, 0, price, false);
  }
}
