// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {Test} from "forge-std/Test.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {PoolInitPreprocessor} from "../lib/metric-core/test/PoolInitPreprocessor.sol";
import {MetricOmmPoolStateView} from "../contracts/common/MetricOmmPoolStateView.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";
import {MetricOmmPoolLiquidityAdder} from "../contracts/MetricOmmPoolLiquidityAdder.sol";
import {IMetricOmmPoolLiquidityAdder} from "../contracts/interfaces/IMetricOmmPoolLiquidityAdder.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";

uint256 constant Q64 = 2 ** 64;

contract MockPriceProviderLPH is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;
  address public baseToken;
  address public quoteToken;

  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  function setTokens(address _baseToken, address _quoteToken) external {
    baseToken = _baseToken;
    quoteToken = _quoteToken;
  }

  function getBidAndAskPrice() external returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external view returns (address) {
    return baseToken;
  }

  function token1() external view returns (address) {
    return quoteToken;
  }

  function getBidPrice() external view returns (uint256) {
    return bidPrice;
  }

  function getBidPriceUi() external view returns (uint256) {
    return bidPrice;
  }

  function getAskPrice() external view returns (uint256) {
    return askPrice;
  }

  function getAskPriceUi() external view returns (uint256) {
    return askPrice;
  }

  function getBidAndAskPriceUi() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function setConfidenceParam(uint256) external {}
  function setCexStep(int256) external {}
  function setClOracle(address, address, uint32) external {}
  function removeClOracle(address) external {}
  function setMaxClDeviation(uint16) external {}
}

contract MetricOmmPoolLiquidityAdderTest is Test, PoolInitPreprocessor {
  MetricOmmPool internal pool;
  RouterTestFactory internal factoryStub;
  MockWETH9 internal weth;
  MockERC20 internal token1;
  MockPriceProviderLPH internal oracle;
  MetricOmmPoolLiquidityAdder internal helper;
  MetricOmmPoolStateView internal stateView;

  address internal alice = makeAddr("alice");

  uint104 constant INITIAL_TOKEN_0_DENSITY = 1e18;
  uint104 constant INITIAL_TOKEN_1_DENSITY = 1e18;
  uint104 constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  uint24 constant PROTOCOL_FEE = 1e4;
  uint24 constant ADMIN_FEE = 5e3;

  function setUp() public {
    factoryStub = new RouterTestFactory();

    weth = new MockWETH9();
    token1 = new MockERC20("Token1", "TK1", 18);

    oracle = new MockPriceProviderLPH();
    oracle.setTokens(address(weth), address(token1));
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));

    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);

    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;

    pool = new MetricOmmPool(
      address(factoryStub),
      address(this),
      makeAddr("adminFeeDest"),
      address(weth),
      address(token1),
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0
    );

    factoryStub.registerPool(
      address(pool),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("adminFeeDest"),
      address(this)
    );

    helper = new MetricOmmPoolLiquidityAdder(address(weth));
    stateView = new MetricOmmPoolStateView(address(factoryStub));

    vm.deal(alice, 100 ether);
    vm.startPrank(alice);
    weth.deposit{value: 20 ether}();
    token1.mint(alice, 5_000_000e18);
    weth.approve(address(helper), type(uint256).max);
    token1.approve(address(helper), type(uint256).max);
    vm.stopPrank();
  }

  function _deltaAbovePrice(int256 binIdx, uint256 shares) internal pure returns (LiquidityDelta memory d) {
    d.binIdxs = new int256[](1);
    d.shares = new uint256[](1);
    d.binIdxs[0] = binIdx;
    d.shares[0] = shares;
  }

  function _deltaTwoBins(int256 bin0, uint256 w0, int256 bin1, uint256 w1)
    internal
    pure
    returns (LiquidityDelta memory d)
  {
    d.binIdxs = new int256[](2);
    d.shares = new uint256[](2);
    d.binIdxs[0] = bin0;
    d.shares[0] = w0;
    d.binIdxs[1] = bin1;
    d.shares[1] = w1;
  }

  function _unconstrainedCursorBounds() internal pure returns (int8, uint104, int8, uint104) {
    return (type(int8).min, 0, type(int8).max, type(uint104).max);
  }

  function test_exactShares_succeedsUnderMax() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 80_000);
    uint256 wethBefore = weth.balanceOf(alice);
    uint256 t1Before = token1.balanceOf(alice);

    vm.prank(alice);
    (uint256 a0, uint256 a1) = helper.addLiquidityExactShares(address(pool), alice, 1, d, 1_000 ether, 1_000 ether, "");

    assertGt(a0 + a1, 0);
    assertLe(wethBefore - weth.balanceOf(alice), 1_000 ether);
    assertLe(t1Before - token1.balanceOf(alice), 1_000 ether);
  }

  function test_exactShares_revertsMaxAmountExceeded() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 80_000);

    vm.prank(alice);
    (uint256 need0, uint256 need1) =
      helper.addLiquidityExactShares(address(pool), alice, 7, d, type(uint256).max, type(uint256).max, "");

    uint256 tight0 = need0 > 0 ? need0 - 1 : type(uint256).max;
    uint256 tight1 = need1 > 0 ? need1 - 1 : type(uint256).max;

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolLiquidityAdder.MaxAmountExceeded.selector, need0, need1, tight0, tight1)
    );
    helper.addLiquidityExactShares(address(pool), alice, 8, d, tight0, tight1, "");
  }

  function test_exactShares_canAddOnBehalfOfAnotherOwner() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 10_000);
    address bob = makeAddr("bob");

    vm.prank(alice);
    helper.addLiquidityExactShares(address(pool), bob, 1, d, type(uint256).max, type(uint256).max, "");

    uint256 bobShares = stateView.positionBinShares(address(pool), bob, 1, int8(4));
    assertGt(bobShares, 0);
  }

  function test_exactShares_revertsOnEmptyDeltas() public {
    LiquidityDelta memory d;
    d.binIdxs = new int256[](0);
    d.shares = new uint256[](0);

    vm.prank(alice);
    vm.expectRevert(IMetricOmmPoolLiquidityAdder.EmptyLiquidityDelta.selector);
    helper.addLiquidityExactShares(address(pool), alice, 10, d, type(uint256).max, type(uint256).max, "");
  }

  function test_exactShares_revertsOnZeroOwner() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 10_000);

    vm.prank(alice);
    vm.expectRevert(IMetricOmmPoolLiquidityAdder.InvalidPositionOwner.selector);
    helper.addLiquidityExactShares(address(pool), address(0), 11, d, type(uint256).max, type(uint256).max, "");
  }

  function test_exactShares_usesMsgSenderAsPayerNotOwner() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 10_000);
    address bob = makeAddr("bob");

    uint256 aliceWethBefore = weth.balanceOf(alice);
    uint256 bobWethBefore = weth.balanceOf(bob);

    vm.prank(alice);
    helper.addLiquidityExactShares(address(pool), bob, 12, d, type(uint256).max, type(uint256).max, "");

    uint256 bobShares = stateView.positionBinShares(address(pool), bob, 12, int8(4));
    assertGt(bobShares, 0);
    assertLt(weth.balanceOf(alice), aliceWethBefore);
    assertEq(weth.balanceOf(bob), bobWethBefore);
  }

  function test_exactShares_overloadDefaultsOwnerToSender() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 12_000);

    vm.prank(alice);
    helper.addLiquidityExactShares(address(pool), 9, d, type(uint256).max, type(uint256).max, "");

    uint256 aliceShares = stateView.positionBinShares(address(pool), alice, 9, int8(4));
    assertGt(aliceShares, 0);
  }

  function test_weighted_scalesDownToRespectCaps() public {
    LiquidityDelta memory w = _deltaAbovePrice(4, 5_000_000);

    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();
    vm.prank(alice);
    (uint256 a0, uint256 a1) =
      helper.addLiquidityWeighted(address(pool), alice, 2, w, 50_000, 50_000, minBin, minPos, maxBin, maxPos, "");

    assertLe(a0, 50_000);
    assertLe(a1, 50_000);
    assertGt(a0 + a1, 0);
  }

  function test_weighted_twoBins_keepsRatioAfterScale() public {
    LiquidityDelta memory w = _deltaTwoBins(3, 400_000, 4, 100_000);

    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();
    vm.prank(alice);
    helper.addLiquidityWeighted(address(pool), alice, 3, w, 30_000, 30_000, minBin, minPos, maxBin, maxPos, "");

    uint256 s3 = stateView.positionBinShares(address(pool), alice, 3, int8(3));
    uint256 s4 = stateView.positionBinShares(address(pool), alice, 3, int8(4));
    assertGt(s3, 0);
    assertGt(s4, 0);
    assertApproxEqRel(s3, s4 * 4, 0.02e18);
  }

  function test_weighted_zeroWeightReverts() public {
    LiquidityDelta memory w = _deltaAbovePrice(2, 0);
    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();
    vm.prank(alice);
    vm.expectRevert(IMetricOmmPoolLiquidityAdder.ZeroWeight.selector);
    helper.addLiquidityWeighted(
      address(pool), alice, 4, w, type(uint256).max, type(uint256).max, minBin, minPos, maxBin, maxPos, ""
    );
  }

  function test_weighted_canAddOnBehalfOfAnotherOwner() public {
    LiquidityDelta memory w = _deltaAbovePrice(4, 100_000);
    address bob = makeAddr("bob");
    uint256 cap = 50_000;

    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();
    vm.prank(alice);
    helper.addLiquidityWeighted(address(pool), bob, 5, w, cap, cap, minBin, minPos, maxBin, maxPos, "");

    uint256 bobShares = stateView.positionBinShares(address(pool), bob, 5, int8(4));
    assertGt(bobShares, 0);
  }

  function test_weighted_revertsCursorOutOfBounds() public {
    LiquidityDelta memory w = _deltaAbovePrice(4, 100_000);
    (, int8 curBinIdx, uint104 curPosInBin,,,) = PoolStateLibrary._slot0(address(pool));

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolLiquidityAdder.CursorOutOfBounds.selector,
        curBinIdx,
        curPosInBin,
        type(int8).min,
        uint104(0),
        int8(-1),
        type(uint104).max
      )
    );
    helper.addLiquidityWeighted(
      address(pool),
      alice,
      7,
      w,
      type(uint256).max,
      type(uint256).max,
      type(int8).min,
      0,
      int8(-1),
      type(uint104).max,
      ""
    );
  }

  function test_weighted_revertsWhenMinimalPositionTooHigh() public {
    LiquidityDelta memory w = _deltaAbovePrice(4, 100_000);
    (, int8 curBinIdx, uint104 curPosInBin,,,) = PoolStateLibrary._slot0(address(pool));

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolLiquidityAdder.CursorOutOfBounds.selector,
        curBinIdx,
        curPosInBin,
        curBinIdx,
        curPosInBin + 1,
        type(int8).max,
        type(uint104).max
      )
    );
    helper.addLiquidityWeighted(
      address(pool),
      alice,
      8,
      w,
      type(uint256).max,
      type(uint256).max,
      curBinIdx,
      curPosInBin + 1,
      type(int8).max,
      type(uint104).max,
      ""
    );
  }

  function _binPackedArrays() internal pure returns (uint256[] memory nn, uint256[] memory neg) {
    nn = new uint256[](1);
    neg = new uint256[](1);
    uint256 packed;
    uint16 lengthE6 = 100;
    for (uint256 j; j < 5; j++) {
      uint48 binData = uint48(lengthE6) | (uint48(0) << 16) | (uint48(0) << 32);
      packed |= uint256(binData) << (j * 48);
    }
    nn[0] = packed;
    neg[0] = packed;
  }
}
