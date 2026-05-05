// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "@metric-core/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig, PoolImmutables} from "@metric-core/types/FactoryStorage.sol";
import {MockERC20} from "@metric-core/mocks/MockERC20.sol";
import {PoolInitPreprocessor} from "../lib/metric-core/test/PoolInitPreprocessor.sol";
import {MetricOmmPoolSwapper} from "../contracts/MetricOmmPoolSwapper.sol";
import {IMetricOmmPoolSwapper} from "../contracts/interfaces/IMetricOmmPoolSwapper.sol";
import {MockWETH9} from "../contracts/mocks/MockWETH9.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";

uint256 constant Q64 = 2 ** 64;

contract MockPriceProviderForRouter is IPriceProvider {
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

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function getTokens() external view returns (address, address) {
    return (baseToken, quoteToken);
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

/// @notice Malicious pool to test callback security
contract MaliciousPoolForRouterTest {
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  int128 public immutable AMOUNT0_DELTA;
  int128 public immutable AMOUNT1_DELTA;

  constructor(address token0, address token1, int128 amount0Delta, int128 amount1Delta) {
    TOKEN0 = token0;
    TOKEN1 = token1;
    AMOUNT0_DELTA = amount0Delta;
    AMOUNT1_DELTA = amount1Delta;
  }

  function swap(address, bool, int128, uint128, bytes calldata data) external returns (int128, int128) {
    MetricOmmPoolSwapper(payable(msg.sender)).metricOmmSwapCallback(int256(AMOUNT0_DELTA), int256(AMOUNT1_DELTA), data);
    return (AMOUNT0_DELTA, AMOUNT1_DELTA);
  }
}

/// @notice Pool that tries nested router swap while a swap is in progress.
contract ReentrantPoolForRouterTest {
  int128 public immutable AMOUNT0_DELTA;
  int128 public immutable AMOUNT1_DELTA;
  bool public nestedAttempted;
  bool public nestedRejectedWithSwapInProgress;

  constructor(int128 amount0Delta, int128 amount1Delta) {
    AMOUNT0_DELTA = amount0Delta;
    AMOUNT1_DELTA = amount1Delta;
  }

  function swap(address recipient, bool zeroForOne, int128 amountSpecified, uint128, bytes calldata data)
    external
    returns (int128, int128)
  {
    nestedAttempted = true;
    try MetricOmmPoolSwapper(payable(msg.sender))
      .swap(
        address(this),
        recipient,
        zeroForOne,
        amountSpecified,
        zeroForOne ? uint128(0) : type(uint128).max,
        type(uint256).max,
        data
      ) {
      revert("nested-swap-should-revert");
    } catch (bytes memory reason) {
      if (reason.length >= 4 && bytes4(reason) == IMetricOmmPoolSwapper.SwapInProgress.selector) {
        nestedRejectedWithSwapInProgress = true;
      }
    }

    MetricOmmPoolSwapper(payable(msg.sender)).metricOmmSwapCallback(int256(AMOUNT0_DELTA), int256(AMOUNT1_DELTA), data);
    return (AMOUNT0_DELTA, AMOUNT1_DELTA);
  }
}

/// @notice Adds liquidity via `addLiquidity` + modify-liquidity callback (matches metric-core flow).
contract LiquidityHelper is IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;

  address public immutable FACTORY;

  constructor(address factory) {
    FACTORY = factory;
  }

  function addLiquidityRange(address pool, uint80 salt, int256 lowerBin, int256 upperBin, uint256 sharesPerBin)
    external
  {
    int256 span = upperBin - lowerBin + 1;
    require(span > 0, "bad range");
    uint256 n = SafeCast.toUint256(span);
    int256[] memory binIdxs = new int256[](n);
    uint256[] memory shares = new uint256[](n);
    for (uint256 i; i < n; i++) {
      binIdxs[i] = lowerBin + SafeCast.toInt256(i);
      shares[i] = sharesPerBin;
    }
    LiquidityDelta memory deltas = LiquidityDelta({binIdxs: binIdxs, shares: shares});
    IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, deltas, "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata)
    external
    override
  {
    PoolImmutables memory imm = IMetricOmmPoolFactory(FACTORY).poolImmutables(msg.sender);
    if (amount0Delta > 0) {
      IERC20(imm.token0).safeTransfer(msg.sender, amount0Delta);
    }
    if (amount1Delta > 0) {
      IERC20(imm.token1).safeTransfer(msg.sender, amount1Delta);
    }
  }
}

contract MetricOmmPoolSwapperNativeTest is Test, PoolInitPreprocessor {
  MetricOmmPool pool;
  MetricOmmPoolSwapper router;
  RouterTestFactory factoryStub;
  MockWETH9 weth;
  MockERC20 token1;
  MockPriceProviderForRouter oracle;
  LiquidityHelper lpContract;

  address lp;
  address swapper;
  address recipient;

  uint104 constant INITIAL_TOKEN_0_DENSITY = 1e18;
  uint104 constant INITIAL_TOKEN_1_DENSITY = 1e18;
  uint104 constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  uint24 constant PROTOCOL_FEE = 1e4;
  uint24 constant ADMIN_FEE = 5e3;

  function setUp() public {
    lp = makeAddr("lp");
    swapper = makeAddr("swapper");
    recipient = makeAddr("recipient");

    factoryStub = new RouterTestFactory();

    weth = new MockWETH9();
    token1 = new MockERC20("Token1", "TK1", 18);

    oracle = new MockPriceProviderForRouter();
    oracle.setTokens(address(weth), address(token1));
    oracle.setBidAndAskPrice(SafeCast.toUint128(Q64), SafeCast.toUint128(Q64));

    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);

    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    pool = new MetricOmmPool(
      address(factoryStub),
      address(weth),
      address(token1),
      address(oracle),
      address(0),
      address(0),
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      false,
      PROTOCOL_FEE,
      ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0,
      0
    );

    factoryStub.registerPool(
      address(pool),
      PoolImmutables({
        token0: address(weth),
        token1: address(token1),
        immutablePriceProvider: address(oracle),
        depositAllowlistProvider: address(0),
        swapAllowlistProvider: address(0),
        reportSwapToPriceProvider: false,
        token0ScaleMultiplier: token0ScaleMultiplier,
        token1ScaleMultiplier: token1ScaleMultiplier,
        initialScaledAmount0PerShareE18: INITIAL_TOKEN_0_DENSITY,
        initialScaledAmount1PerShareE18: INITIAL_TOKEN_1_DENSITY,
        minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
        lowestBin: -5,
        highestBin: 4
      }),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("adminFeeDest"),
      address(this)
    );

    router = new MetricOmmPoolSwapper(address(weth), address(factoryStub));

    lpContract = new LiquidityHelper(address(factoryStub));

    vm.deal(lp, 100 ether);
    vm.startPrank(lp);
    weth.deposit{value: 10 ether}();
    token1.mint(lp, 1_000_000e18);
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    weth.transfer(address(lpContract), 5 ether);
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    token1.transfer(address(lpContract), 500_000e18);
    vm.stopPrank();

    vm.startPrank(address(lpContract));
    weth.approve(address(pool), type(uint256).max);
    token1.approve(address(pool), type(uint256).max);
    vm.stopPrank();

    lpContract.addLiquidityRange(address(pool), 0, -4, 4, 100_000);

    vm.deal(swapper, 100 ether);
    token1.mint(swapper, 1_000_000e18);
    vm.startPrank(swapper);
    weth.deposit{value: 20 ether}();
    weth.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);
    vm.stopPrank();
  }

  function test_swapExactInputNativeForTokens() public {
    uint128 amountIn = 2_500;

    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    (uint256 amountOut, uint256 amountInUsed) = router.swapExactInputNativeForTokens{value: amountIn}(
      address(pool), recipient, true, amountIn, 0, 0, type(uint256).max
    );

    assertEq(amountInUsed, amountIn, "amountInUsed");
    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "recipient received tokens");
    assertEq(address(router).balance, 0, "router ETH balance is 0");
    assertEq(weth.balanceOf(address(router)), 0, "router WETH balance is 0");
  }

  function test_swapExactOutputNativeForTokens_refund() public {
    uint128 amountOutDesired = 1_500;
    uint256 maxAmountIn = 10_000;

    uint256 ethBefore = swapper.balance;
    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    (uint256 amountOut, uint256 amountInUsed) = router.swapExactOutputNativeForTokens{value: maxAmountIn}(
      address(pool), recipient, true, amountOutDesired, 0, maxAmountIn, type(uint256).max
    );

    assertEq(amountOut, amountOutDesired, "exact output");
    assertLe(amountInUsed, maxAmountIn, "input <= max");
    assertEq(ethBefore - swapper.balance, amountInUsed, "swapper spent correct ETH");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "recipient received tokens");
    assertEq(address(router).balance, 0, "router ETH balance is 0");
    assertEq(weth.balanceOf(address(router)), 0, "router WETH balance is 0");
  }

  function test_swapExactInputTokensForNative_unwrap() public {
    uint128 amountIn = 2_500;

    uint256 ethBefore = recipient.balance;

    vm.prank(swapper);
    (uint256 amountOut, uint256 amountInUsed) = router.swapExactInputTokensForNative(
      address(pool), recipient, false, amountIn, type(uint128).max, 0, type(uint256).max
    );

    assertEq(amountInUsed, amountIn, "amountInUsed");
    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(recipient.balance - ethBefore, amountOut, "recipient received ETH");
    assertEq(address(router).balance, 0, "router ETH balance is 0");
    assertEq(weth.balanceOf(address(router)), 0, "router WETH balance is 0");
  }

  function test_swap_cannotDrainThirdPartyApprovals() public {
    address victim = makeAddr("victim");

    token1.mint(victim, 1_000_000e18);
    vm.prank(victim);
    token1.approve(address(router), type(uint256).max);

    uint256 victimToken1Before = token1.balanceOf(victim);

    MaliciousPoolForRouterTest malicious = new MaliciousPoolForRouterTest(address(weth), address(token1), 0, 1000);

    factoryStub.registerPool(
      address(malicious),
      PoolImmutables({
        token0: address(weth),
        token1: address(token1),
        immutablePriceProvider: address(0),
        depositAllowlistProvider: address(0),
        swapAllowlistProvider: address(0),
        reportSwapToPriceProvider: false,
        token0ScaleMultiplier: 1,
        token1ScaleMultiplier: 1,
        initialScaledAmount0PerShareE18: 1,
        initialScaledAmount1PerShareE18: 1,
        minimalMintableLiquidity: 1,
        lowestBin: 0,
        highestBin: 0
      }),
      PoolFeeConfig({protocolSpreadFeeE6: 0, adminSpreadFeeE6: 0, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0}),
      address(0),
      address(0)
    );

    uint256 poolToken1Before = token1.balanceOf(address(malicious));

    vm.prank(swapper);
    router.swap(address(malicious), swapper, false, 1000, type(uint128).max, type(uint256).max);

    assertEq(token1.balanceOf(victim), victimToken1Before, "victim funds unchanged");
    assertEq(token1.balanceOf(address(malicious)) - poolToken1Before, 1000, "malicious pool received from swapper");
  }

  function test_swap_revertsOnExpiredDeadline() public {
    uint256 deadline = 12344;
    uint256 nowTs = 12345;

    vm.warp(nowTs);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolSwapper.TransactionExpired.selector, deadline, nowTs));
    router.swap(address(pool), recipient, true, 1, 0, deadline);
  }

  function test_swap_revertsOnInvalidPriceLimitSentinel() public {
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolSwapper.InvalidPriceLimitForDirection.selector, false, uint128(0))
    );
    router.swap(address(pool), recipient, false, 1, 0, type(uint256).max);

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolSwapper.InvalidPriceLimitForDirection.selector, true, type(uint128).max)
    );
    router.swap(address(pool), recipient, true, 1, type(uint128).max, type(uint256).max);
  }

  function test_swap_rejectsNestedSwapAndClearsContext() public {
    ReentrantPoolForRouterTest reentrant = new ReentrantPoolForRouterTest(1000, -1);
    factoryStub.registerPool(
      address(reentrant),
      PoolImmutables({
        token0: address(weth),
        token1: address(token1),
        immutablePriceProvider: address(0),
        depositAllowlistProvider: address(0),
        swapAllowlistProvider: address(0),
        reportSwapToPriceProvider: false,
        token0ScaleMultiplier: 1,
        token1ScaleMultiplier: 1,
        initialScaledAmount0PerShareE18: 1,
        initialScaledAmount1PerShareE18: 1,
        minimalMintableLiquidity: 1,
        lowestBin: 0,
        highestBin: 0
      }),
      PoolFeeConfig({protocolSpreadFeeE6: 0, adminSpreadFeeE6: 0, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0}),
      address(0),
      address(0)
    );

    vm.prank(swapper);
    (int128 a0, int128 a1) = router.swap(address(reentrant), recipient, true, 1000, 0, type(uint256).max);
    assertEq(a0, 1000);
    assertEq(a1, -1);
    assertTrue(reentrant.nestedAttempted(), "nested call attempted");
    assertTrue(reentrant.nestedRejectedWithSwapInProgress(), "nested call rejected by guard");

    // Verify context is cleared and router remains usable in same test transaction.
    vm.prank(swapper);
    router.swap(address(pool), recipient, true, 1000, 0, type(uint256).max);
  }

  function test_swap_twoSequentialCallsSameTx() public {
    vm.startPrank(swapper);
    router.swap(address(pool), recipient, true, 1000, 0, type(uint256).max);
    router.swap(address(pool), recipient, true, 1000, 0, type(uint256).max);
    vm.stopPrank();
  }

  function test_swapExactOutputTokensForNative() public {
    uint128 amountOutDesired = 1_000;
    uint256 maxAmountIn = 10_000;

    uint256 ethBefore = recipient.balance;
    uint256 token1Before = token1.balanceOf(swapper);

    vm.prank(swapper);
    (uint256 amountOut, uint256 amountInUsed) = router.swapExactOutputTokensForNative(
      address(pool), recipient, false, amountOutDesired, type(uint128).max, maxAmountIn, type(uint256).max
    );

    assertEq(amountOut, amountOutDesired, "exact output");
    assertLe(amountInUsed, maxAmountIn, "input <= max");
    assertEq(recipient.balance - ethBefore, amountOut, "recipient received ETH");
    assertEq(token1Before - token1.balanceOf(swapper), amountInUsed, "swapper spent tokens");
    assertEq(address(router).balance, 0, "router ETH balance is 0");
    assertEq(weth.balanceOf(address(router)), 0, "router WETH balance is 0");
  }

  function testFuzz_swap_noRevertWhenSufficientLiquidity_andSpecifiedMatches(
    uint96 rawAmount,
    bool zeroForOne,
    bool exactInput
  ) public {
    uint128 amount = uint128(bound(uint256(rawAmount), 1, 1_000_000));
    int128 amountSpecified = exactInput
      // forge-lint: disable-next-line(unsafe-typecast)
      ? int128(amount)
      // forge-lint: disable-next-line(unsafe-typecast)
      : -int128(amount);
    uint128 priceLimitX64 = zeroForOne ? 0 : type(uint128).max;

    (int128 q0, int128 q1) =
      router.quoteSwap(address(pool), zeroForOne, amountSpecified, priceLimitX64, uint128(Q64), uint128(Q64));
    int128 specifiedSideDelta = exactInput ? (zeroForOne ? q0 : q1) : (zeroForOne ? q1 : q0);
    vm.assume(specifiedSideDelta == amountSpecified);

    vm.prank(swapper);
    (int128 a0, int128 a1) =
      router.swap(address(pool), recipient, zeroForOne, amountSpecified, priceLimitX64, type(uint256).max);

    int128 actualSpecifiedSideDelta = exactInput ? (zeroForOne ? a0 : a1) : (zeroForOne ? a1 : a0);
    assertEq(actualSpecifiedSideDelta, amountSpecified, "specified side delta must match amountSpecified");
    assertEq(a0, q0, "amount0 delta mismatch vs quote");
    assertEq(a1, q1, "amount1 delta mismatch vs quote");
  }

  /// @dev One packed word: five bins, each with `lengthE6` distance span and zero add fees.
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
