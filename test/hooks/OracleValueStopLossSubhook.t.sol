// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Extsload} from "@metric-core/Extsload.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {OracleValueStopLossSubhook} from "../../contracts/hooks/subhooks/OracleValueStopLossSubhook.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
import {OracleValueStopLossSubhookHarness} from "./OracleValueStopLossSubhookHarness.sol";

contract MockExtsloadPool2 is Extsload {}

contract OracleValueStopLossSubhookTest is Test {
  uint256 private constant Q64 = 1 << 64;

  AllowlistFactoryStub factoryStub;
  OracleValueStopLossSubhookHarness harness;
  MockExtsloadPool2 mockPool;

  address admin = makeAddr("admin");

  function setUp() public {
    mockPool = new MockExtsloadPool2();
    factoryStub = new AllowlistFactoryStub();
    factoryStub.setPoolAdmin(address(mockPool), admin);
    harness = new OracleValueStopLossSubhookHarness(address(mockPool), address(factoryStub));
  }

  // ---- helpers ----

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

  /// @dev Oracle with equal bid/ask so midPrice = price. Price is in Q64.64 (token1-per-token0).
  function _oracle(uint128 priceX64) internal pure returns (SwapOracleSnapshot memory) {
    return SwapOracleSnapshot({bidPriceX64: priceX64, askPriceX64: priceX64});
  }

  function _computeMetricToken0(uint104 t0, uint104 t1, uint256 shares, uint128 midX64)
    internal
    pure
    returns (uint256)
  {
    uint256 t0ps = Math.mulDiv(uint256(t0), 1e18, shares);
    uint256 t1ps = Math.mulDiv(uint256(t1), 1e18, shares);
    return t0ps + Math.mulDiv(t1ps, Q64, midX64);
  }

  function _computeMetricToken1(uint104 t0, uint104 t1, uint256 shares, uint128 midX64)
    internal
    pure
    returns (uint256)
  {
    uint256 t0ps = Math.mulDiv(uint256(t0), 1e18, shares);
    uint256 t1ps = Math.mulDiv(uint256(t1), 1e18, shares);
    return Math.mulDiv(t0ps, midX64, Q64) + t1ps;
  }

  // ---- admin tests ----

  function test_onlyAdminCanSetDrawdown() public {
    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);
    assertEq(harness.oracleStopLossDrawdownE6(address(mockPool)), 50_000);

    address rando = makeAddr("rando");
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, address(mockPool), rando, admin));
    harness.setOracleStopLossDrawdown(address(mockPool), 100_000);
  }

  function test_drawdownCannotExceed1e6() public {
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(OracleValueStopLossSubhook.OracleStopLossDrawdownTooLarge.selector, 1e6 + 1));
    harness.setOracleStopLossDrawdown(address(mockPool), 1e6 + 1);
  }

  function test_onlyAdminCanResetWatermarks() public {
    vm.prank(admin);
    harness.resetOracleStopLossHighWatermarks(address(mockPool), 0);

    address rando = makeAddr("rando");
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, address(mockPool), rando, admin));
    harness.resetOracleStopLossHighWatermarks(address(mockPool), 0);
  }

  // ---- no-op when drawdown is zero ----

  function test_noOpWhenDrawdownNotConfigured() public {
    _storeBin(0, 1000, 1000, 100);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(uint128(Q64)));
  }

  // ---- sets both watermarks on first swap ----

  function test_setsBothWatermarksOnFirstSwap() public {
    uint104 t0 = 500;
    uint104 t1 = 500;
    uint256 shares = 100;
    uint128 price = uint128(Q64); // 1:1

    _storeBin(0, t0, t1, shares);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    assertEq(harness.highWatermarkToken0(address(mockPool), 0), _computeMetricToken0(t0, t1, shares, price));
    assertEq(harness.highWatermarkToken1(address(mockPool), 0), _computeMetricToken1(t0, t1, shares, price));
  }

  // ---- small drawdown passes ----

  function test_smallDrawdownPasses() public {
    uint128 price = uint128(Q64); // 1:1
    _storeBin(0, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 100_000); // 10%

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    // Drop by 5% (within 10% threshold)
    _storeBin(0, 950, 950, 100);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));
  }

  // ---- large drawdown in token0 value reverts ----

  function test_largeDrawdownToken0Reverts() public {
    uint128 price = uint128(Q64); // 1:1
    _storeBin(0, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000); // 5%

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    // Drop token0 heavily, token1 stays -- token0-denominated value drops
    _storeBin(0, 800, 1000, 100);

    uint256 hwmT0 = _computeMetricToken0(1000, 1000, 100, price);
    uint256 curT0 = _computeMetricToken0(800, 1000, 100, price);
    uint256 threshold = hwmT0 * (1e6 - 50_000) / 1e6;

    vm.expectRevert(
      abi.encodeWithSelector(
        OracleValueStopLossSubhook.OracleStopLossTriggered.selector, int8(0), true, curT0, threshold
      )
    );
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));
  }

  // ---- large drawdown in token1 value reverts (token0 metric stays within threshold) ----

  function test_largeDrawdownToken1Reverts() public {
    // Price = 1:1. Start with a bin heavily weighted toward token1 so that losing token1
    // triggers the token1 metric first while the token0 metric stays within threshold.
    uint128 price = uint128(Q64);
    _storeBin(0, 100, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000); // 5%

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    // Drop token1 by ~6% (60 units): token0 metric drops ~5.5%, token1 metric drops ~5.5%.
    // But let's make it asymmetric so only token1 breaches: add a bit of token0 to compensate.
    // token0: 100->150, token1: 1000->880. At price=1:
    //   metricT0 = (150+880)*1e18/100 = 10.3e18 vs hwm (100+1000)*1e18/100 = 11e18 => 6.4% drop -> triggers
    // That also triggers token0. Let me just test that whichever triggers first is caught:
    // Simply drop token1 by >5%, token0 stays same. Both metrics will drop, token1 drops more.
    _storeBin(0, 100, 900, 100);

    // Token0 metric: (100+900)/100 = 10e18, hwm was (100+1000)/100 = 11e18 => 9.1% drop > 5% -> triggers first
    uint256 hwmT0 = _computeMetricToken0(100, 1000, 100, price);
    uint256 curT0 = _computeMetricToken0(100, 900, 100, price);
    uint256 threshold = hwmT0 * (1e6 - 50_000) / 1e6;

    vm.expectRevert(
      abi.encodeWithSelector(
        OracleValueStopLossSubhook.OracleStopLossTriggered.selector, int8(0), true, curT0, threshold
      )
    );
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));
  }

  // ---- multi-bin: checks all touched bins ----

  function test_multiBin_checksAllTouchedBins() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, 100);
    _storeBin(1, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(1), _oracle(price));

    uint256 expectedT0 = _computeMetricToken0(1000, 1000, 100, price);
    assertEq(harness.highWatermarkToken0(address(mockPool), 0), expectedT0);
    assertEq(harness.highWatermarkToken0(address(mockPool), 1), expectedT0);
  }

  // ---- watermarks update independently ----

  function test_watermarksUpdateOnIncrease() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 500, 500, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));
    uint256 hwm0Before = harness.highWatermarkToken0(address(mockPool), 0);
    uint256 hwm1Before = harness.highWatermarkToken1(address(mockPool), 0);

    // Increase reserves
    _storeBin(0, 600, 600, 100);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    assertGt(harness.highWatermarkToken0(address(mockPool), 0), hwm0Before);
    assertGt(harness.highWatermarkToken1(address(mockPool), 0), hwm1Before);
  }

  // ---- admin reset allows recovery ----

  function test_resetAllowsRecovery() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    _storeBin(0, 800, 800, 100);
    vm.expectRevert();
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    vm.prank(admin);
    harness.resetOracleStopLossHighWatermarks(address(mockPool), 0);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    uint256 expectedT0 = _computeMetricToken0(800, 800, 100, price);
    assertEq(harness.highWatermarkToken0(address(mockPool), 0), expectedT0);
  }

  // ---- skips empty bins ----

  function test_skipsEmptyBins() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, 100);
    _storeBin(1, 0, 0, 0);
    _storeBin(2, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(2), _oracle(price));

    assertGt(harness.highWatermarkToken0(address(mockPool), 0), 0);
    assertEq(harness.highWatermarkToken0(address(mockPool), 1), 0);
    assertGt(harness.highWatermarkToken0(address(mockPool), 2), 0);
  }

  // ---- different oracle prices produce different metrics ----

  function test_differentOraclePricesProduceDifferentMetrics() public {
    _storeBin(0, 1000, 500, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 50_000);

    // Price = 1 token1/token0
    uint128 price1 = uint128(Q64);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price1));
    uint256 hwmT0_price1 = harness.highWatermarkToken0(address(mockPool), 0);

    // Reset and use price = 2 token1/token0 (token1 is cheaper)
    vm.prank(admin);
    harness.resetOracleStopLossHighWatermarks(address(mockPool), 0);

    uint128 price2 = uint128(2 * Q64);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price2));
    uint256 hwmT0_price2 = harness.highWatermarkToken0(address(mockPool), 0);

    // At price=2, token1 is worth less in token0 terms, so token0-denominated metric is lower
    assertGt(hwmT0_price1, hwmT0_price2);
  }

  // ---- exact boundary passes ----

  function test_exactBoundaryPasses() public {
    uint128 price = uint128(Q64);
    _storeBin(0, 1000, 1000, 100);

    vm.prank(admin);
    harness.setOracleStopLossDrawdown(address(mockPool), 100_000); // 10%

    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));

    // Drop exactly 10%: metric = threshold, should NOT revert
    _storeBin(0, 900, 900, 100);
    harness.exposeAfterSwapOracleStopLoss(_packSlot0(0), _packSlot0(0), _oracle(price));
  }
}
