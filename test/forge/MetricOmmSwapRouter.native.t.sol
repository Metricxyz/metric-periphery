// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider.sol";
import {MetricOmmSwapRouter} from "../../contracts/MetricOmmSwapRouter.sol";
import {MockWETH9} from "../../contracts/mocks/MockWETH9.sol";
import {MockERC20} from "@metric-core/mocks/MockERC20.sol";

uint256 constant Q64 = 2 ** 64;

contract MockPriceProviderForRouter is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;

  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }
}

/// @notice Malicious pool to test callback security
contract MaliciousPoolForRouterTest {
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  int128 public immutable AMOUNT0_DELTA;
  int128 public immutable AMOUNT1_DELTA;

  constructor(address _token0, address _token1, int128 _amount0Delta, int128 _amount1Delta) {
    TOKEN0 = _token0;
    TOKEN1 = _token1;
    AMOUNT0_DELTA = _amount0Delta;
    AMOUNT1_DELTA = _amount1Delta;
  }

  function swap(address, bool, int128, uint128, bytes calldata data) external returns (int128, int128) {
    MetricOmmSwapRouter(payable(msg.sender)).metricOmmSwapCallback(int256(AMOUNT0_DELTA), int256(AMOUNT1_DELTA), data);
    return (AMOUNT0_DELTA, AMOUNT1_DELTA);
  }

  function getImmutables()
    external
    view
    returns (
      address factory,
      address priceProvider,
      address token0,
      address token1,
      uint104 initialToken0PerDistUnitPerShareE18,
      uint104 initialToken1PerDistUnitPerShareE18,
      uint104 minimalMintableLiquidity,
      uint256 maxDriftE8,
      uint256 maxDriftDecayPerSecondE8,
      int16 lowestBin,
      int16 highestBin,
      uint256 token0ScaleMultiplier,
      uint256 token1ScaleMultiplier
    )
  {
    return (address(0), address(0), TOKEN0, TOKEN1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  }
}

/// @notice Simple liquidity provider
contract LiquidityProvider {
  function addLiquidity(address pool, int16 binLower, int16 binUpper, uint104 shares, uint80 salt) external {
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 numBins = uint256(int256(binUpper - binLower + 1));
    IMetricOmmPoolActions.LiquidityDelta[] memory deltas = new IMetricOmmPoolActions.LiquidityDelta[](numBins);
    for (uint256 i = 0; i < numBins; i++) {
      // forge-lint: disable-next-line(unsafe-typecast)
      deltas[i] = IMetricOmmPoolActions.LiquidityDelta({bin: binLower + int16(int256(i)), deltaShares: int104(shares)});
    }
    IMetricOmmPoolActions(pool).modifyLiquidity(salt, deltas, type(int128).max, type(int128).max);
  }
}

contract MetricOmmSwapRouterNativeTest is Test {
  MetricOmmPool pool;
  MetricOmmSwapRouter router;
  MockWETH9 weth;
  MockERC20 token1;
  MockPriceProviderForRouter oracle;
  LiquidityProvider lpContract;

  address lp;
  address swapper;
  address recipient;

  // Default constructor parameters (kept in sync with other pool tests)
  uint104 constant INITIAL_TOKEN_0_DENSITY = 1e18;
  uint104 constant INITIAL_TOKEN_1_DENSITY = 1e18;
  uint104 constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  uint256 constant MAX_DRIFT = 5e6;
  uint256 constant DRIFT_DECAY_PER_SECOND = 1e4;
  int32 constant TICK_DISTANCE_MULTIPLIER = 1e6;
  uint24 constant PROTOCOL_FEE = 1e4;
  uint24 constant ADMIN_FEE = 5e3;

  function setUp() public {
    lp = makeAddr("lp");
    swapper = makeAddr("swapper");
    recipient = makeAddr("recipient");

    weth = new MockWETH9();
    token1 = new MockERC20("Token1", "TK1", 18);

    oracle = new MockPriceProviderForRouter();
    // forge-lint: disable-next-line(unsafe-typecast)
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64));

    uint256[] memory binData = _createBinDataArray();

    pool = new MetricOmmPool(
      address(this),
      address(this),
      address(weth),
      address(token1),
      address(oracle),
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      MAX_DRIFT,
      DRIFT_DECAY_PER_SECOND,
      PROTOCOL_FEE,
      ADMIN_FEE,
      address(0xBEEF),
      0,
      binData,
      binData
    );

    router = new MetricOmmSwapRouter(address(weth));

    lpContract = new LiquidityProvider();

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

    lpContract.addLiquidity(address(pool), -10, 10, 100_000, 0);

    vm.deal(swapper, 100 ether);
    token1.mint(swapper, 1_000_000e18);
    vm.prank(swapper);
    token1.approve(address(router), type(uint256).max);
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

    uint256 poolToken1Before = token1.balanceOf(address(malicious));

    vm.prank(swapper);
    router.swap(address(malicious), swapper, true, 1, 0, type(uint256).max);

    assertEq(token1.balanceOf(victim), victimToken1Before, "victim funds unchanged");
    assertEq(token1.balanceOf(address(malicious)) - poolToken1Before, 1000, "malicious pool received from swapper");
  }

  function test_swap_revertsOnExpiredDeadline() public {
    uint256 deadline = 12344;
    uint256 nowTs = 12345;

    vm.warp(nowTs);
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(MetricOmmSwapRouter.TransactionExpired.selector, deadline, nowTs));
    router.swap(address(pool), recipient, true, 1, 0, deadline);
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

  function _createBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](64);
    for (uint256 i = 0; i < 64; i++) {
      uint256 packed = 0;
      for (uint256 j = 0; j < 4; j++) {
        uint24 lengthE6 = 1;
        uint16 buyFee = 0;
        uint16 sellFee = 0;
        uint64 binData = uint64(lengthE6) | (uint64(buyFee) << 24) | (uint64(sellFee) << 40);
        packed |= uint256(binData) << (j * 64);
      }
      binDataArray[i] = packed;
    }
  }
}
