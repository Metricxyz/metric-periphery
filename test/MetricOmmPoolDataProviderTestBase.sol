// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "@metric-core/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {SwapMath} from "@metric-core/libraries/SwapMath.sol";
import {PoolInitPreprocessor} from "../lib/metric-core/test/PoolInitPreprocessor.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";

contract MockPriceProviderSDH is IPriceProvider {
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

contract LiquiditySeederForSwapData is IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;

  function addLiquidityRange(address pool, uint80 salt, int256 lowerBin, int256 upperBin, uint256 sharesPerBin)
    external
  {
    int256 span = upperBin - lowerBin + 1;
    require(span > 0, "bad range");
    uint256 n = uint256(span);
    int256[] memory binIdxs = new int256[](n);
    uint256[] memory shares = new uint256[](n);
    for (uint256 i; i < n; i++) {
      binIdxs[i] = lowerBin + int256(i);
      shares[i] = sharesPerBin;
    }
    LiquidityDelta memory deltas = LiquidityDelta({binIdxs: binIdxs, shares: shares});
    IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, deltas, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata)
    external
    override
  {
    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) IERC20(imm.token0).safeTransfer(msg.sender, amount0Delta);
    if (amount1Delta > 0) IERC20(imm.token1).safeTransfer(msg.sender, amount1Delta);
  }
}

/// @notice Shared pool deploy, oracle mock, and swap helpers for swap-data and depth integration tests.
abstract contract MetricOmmPoolDataProviderTestBase is Test, PoolInitPreprocessor {
  uint256 internal constant Q64 = 2 ** 64;
  uint256 internal constant ONE_E6 = 1e6;
  uint256 internal constant ONE_E8 = 1e8;

  uint104 internal constant INITIAL_TOKEN_0_DENSITY = 1e18;
  uint104 internal constant INITIAL_TOKEN_1_DENSITY = 1e18;
  uint104 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  uint24 internal constant PROTOCOL_SPREAD = 300;
  uint24 internal constant ADMIN_SPREAD = 700;
  uint24 internal constant PROTOCOL_NOTIONAL = 5_000;
  uint24 internal constant ADMIN_NOTIONAL = 2_000;
  uint256 internal constant SHARES_PER_BIN = 200_000 * 1e6;

  /// @dev Forge `assertApproxEqRel` uses `1e18 = 100%`, so `0.001% = 1e-5 * 1e18 = 1e13`.
  uint256 internal constant MAX_REL_ERR_0_001_BPS = 1e11;

  function _deployCase(
    uint8 token0Decimals,
    uint8 token1Decimals,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint8 warmupMode,
    uint256 sharesPerBinOverride,
    bool fullBinRange
  )
    internal
    returns (
      MetricOmmPool pool,
      MockPriceProviderSDH oracle,
      MockERC20 token0,
      MockERC20 token1,
      MetricOmmPoolDataProvider helper,
      MetricOmmSimpleRouter router,
      RouterTestFactory factoryStub,
      LiquiditySeederForSwapData seeder
    )
  {
    factoryStub = new RouterTestFactory();
    token0 = new MockERC20("Token0", "TK0", token0Decimals);
    token1 = new MockERC20("Token1", "TK1", token1Decimals);

    oracle = new MockPriceProviderSDH();
    oracle.setTokens(address(token0), address(token1));
    oracle.setBidAndAskPrice(bidPriceX64, askPriceX64);

    (uint256[] memory nnPacked, uint256[] memory negPacked) =
      fullBinRange ? _fullRangeBinPackedArrays(100, 1200, 2300) : _binPackedArrays(100, 1200, 2300);
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(token0), address(token1));

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;

    pool = new MetricOmmPool(
      address(factoryStub),
      address(this),
      makeAddr("adminFeeDest"),
      address(token0),
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
      PROTOCOL_SPREAD + ADMIN_SPREAD,
      0,
      nnStates,
      negStates,
      PROTOCOL_NOTIONAL + ADMIN_NOTIONAL
    );

    factoryStub.registerPool(
      address(pool),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_SPREAD,
        adminSpreadFeeE6: ADMIN_SPREAD,
        protocolNotionalFeeE8: PROTOCOL_NOTIONAL,
        adminNotionalFeeE8: ADMIN_NOTIONAL
      }),
      makeAddr("adminFeeDest"),
      address(this)
    );

    helper = new MetricOmmPoolDataProvider(address(factoryStub));
    router = new MetricOmmSimpleRouter(address(new MockWETH9()), address(factoryStub));
    seeder = new LiquiditySeederForSwapData();

    uint256 sharesPerBin = sharesPerBinOverride == 0 ? SHARES_PER_BIN : sharesPerBinOverride;
    uint256 mintFactor = sharesPerBin / SHARES_PER_BIN;
    if (mintFactor < 1) mintFactor = 1;
    if (mintFactor > 5000) mintFactor = 5000;
    uint256 seederMintUnits = fullBinRange ? mintFactor * 250_000_000 : mintFactor * 1_000_000;
    token0.mint(address(seeder), seederMintUnits * 10 ** token0Decimals);
    token1.mint(address(seeder), seederMintUnits * 10 ** token1Decimals);
    vm.startPrank(address(seeder));
    token0.approve(address(pool), type(uint256).max);
    token1.approve(address(pool), type(uint256).max);
    vm.stopPrank();
    if (fullBinRange) {
      seeder.addLiquidityRange(address(pool), 0, -128, 127, sharesPerBin);
    } else {
      seeder.addLiquidityRange(address(pool), 0, -4, 4, sharesPerBin);
    }

    uint256 selfMintUnits = fullBinRange ? mintFactor * 25_000_000 : mintFactor * 100_000;
    token0.mint(address(this), selfMintUnits * 10 ** token0Decimals);
    token1.mint(address(this), selfMintUnits * 10 ** token1Decimals);
    token0.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);

    if (warmupMode == 1) {
      _tryWarmupSwap(router, address(pool), true, _smallTradeAmount(token0Decimals) * 2);
    } else if (warmupMode == 2) {
      _tryWarmupSwap(router, address(pool), false, _smallTradeAmount(token1Decimals) * 2);
    }
  }

  function _tryWarmupSwap(MetricOmmSimpleRouter router, address pool, bool zeroForOne, uint256 amountIn) internal {
    try this.routerExactInputExternal(router, pool, zeroForOne, amountIn) returns (uint256) {}
    catch (bytes memory reason) {
      if (reason.length >= 4 && bytes4(reason) != IMetricOmmSimpleRouter.InvalidSwapDeltas.selector) {
        assembly ("memory-safe") {
          revert(add(reason, 32), mload(reason))
        }
      }
    }
  }

  function _toX64(uint256 e6Ratio) internal pure returns (uint128) {
    return uint128(Math.mulDiv(Q64, e6Ratio, ONE_E6));
  }

  function _smallTradeAmount(uint8 decimals) internal pure returns (uint256) {
    uint256 unit = 10 ** decimals;
    uint256 amount = unit / 1e12;
    return amount == 0 ? 1 : amount;
  }

  function _scaleMultiplierFromDecimals(uint8 decimals) internal pure returns (uint256) {
    if (decimals >= 18) return 1;
    return 10 ** (18 - decimals);
  }

  function _expectedBestBidAsk(address pool, address factory, address oracle)
    internal
    returns (uint256 expectedBid, uint256 expectedAsk)
  {
    (uint128 bidFromOracleX64, uint128 askFromOracleX64) = IPriceProvider(oracle).getBidAndAskPrice();
    (uint256 midPriceX64, uint256 baseFeeX64) =
      SwapMath.midAndSpreadFeeX64FromBidAsk(uint256(bidFromOracleX64), uint256(askFromOracleX64));
    (, int8 curBinIdx, uint104 curPosInBin, int24 curBinDistFromProvidedPriceE6,,) = PoolStateLibrary._slot0(pool);
    (,, uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6) = PoolStateLibrary._binState(pool, curBinIdx);
    (,, uint24 protocolNotionalFeeE8, uint24 adminNotionalFeeE8) = IMetricOmmPoolFactory(factory).poolFeeConfig(pool);
    uint256 notionalFeeE8 = uint256(protocolNotionalFeeE8) + uint256(adminNotionalFeeE8);

    uint256 lowerPriceX64 = _distanceE6ToPriceX64(curBinDistFromProvidedPriceE6, midPriceX64, Math.Rounding.Floor);
    int256 distUpperE6 = int256(curBinDistFromProvidedPriceE6) + int256(uint256(lengthE6));
    uint256 upperPriceX64 = _distanceE6ToPriceX64(int24(distUpperE6), midPriceX64, Math.Rounding.Floor);
    uint256 marginalPriceX64 =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, curPosInBin, Math.Rounding.Floor);
    uint256 buyFeeX64 = baseFeeX64 + Math.mulDiv(uint256(addFeeBuyE6), Q64, ONE_E6);
    uint256 sellFeeX64 = baseFeeX64 + Math.mulDiv(uint256(addFeeSellE6), Q64, ONE_E6);

    uint256 askBeforeNotional = Math.mulDiv(marginalPriceX64, Q64 + buyFeeX64, Q64, Math.Rounding.Ceil);
    uint256 bidAfterSpread = Math.mulDiv(marginalPriceX64, Q64, Q64 + sellFeeX64, Math.Rounding.Floor);
    expectedAsk = Math.mulDiv(askBeforeNotional, ONE_E8, ONE_E8 - notionalFeeE8, Math.Rounding.Ceil);
    expectedBid = Math.mulDiv(bidAfterSpread, ONE_E8 - notionalFeeE8, ONE_E8, Math.Rounding.Floor);
  }

  function _distanceE6ToPriceX64(int24 distanceValueE6, uint256 midPriceX64, Math.Rounding rounding)
    internal
    pure
    returns (uint256)
  {
    if (distanceValueE6 >= 0) {
      return Math.mulDiv(midPriceX64, ONE_E6 + uint256(int256(distanceValueE6)), ONE_E6, rounding);
    }
    uint256 absNeg = uint256(-int256(distanceValueE6));
    return Math.mulDiv(midPriceX64, ONE_E6 - absNeg, ONE_E6, rounding);
  }

  function _binPackedArrays(uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
    internal
    pure
    returns (uint256[] memory nn, uint256[] memory neg)
  {
    nn = new uint256[](1);
    neg = new uint256[](1);
    uint256 packed;
    for (uint256 j; j < 5; j++) {
      uint48 binData = uint48(lengthE6) | (uint48(addFeeBuyE6) << 16) | (uint48(addFeeSellE6) << 32);
      packed |= uint256(binData) << (j * 48);
    }
    nn[0] = packed;
    neg[0] = packed;
  }

  /// @dev `MetricOmmPool` constructor accepts up to 128 non-negative bins (0..127) and 128 negative bins (-1..-128).
  function _fullRangeBinPackedArrays(uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
    internal
    pure
    returns (uint256[] memory nn, uint256[] memory neg)
  {
    uint256 wordCount = 26;
    nn = new uint256[](wordCount);
    neg = new uint256[](wordCount);
    uint48 binData = uint48(lengthE6) | (uint48(addFeeBuyE6) << 16) | (uint48(addFeeSellE6) << 32);
    for (uint256 w; w < wordCount; w++) {
      uint256 packed;
      for (uint256 j; j < 5; j++) {
        uint256 globalBin = w * 5 + j;
        if (globalBin >= 128) break;
        packed |= uint256(binData) << (j * 48);
      }
      nn[w] = packed;
      neg[w] = packed;
    }
  }

  function _swapExactOutputUntilNonZero(
    MetricOmmSimpleRouter router,
    address pool,
    bool zeroForOne,
    uint256 amountOutStart
  ) internal returns (uint256 amountOut, uint256 amountInUsed) {
    uint256 amountOutDesired = amountOutStart;
    for (uint256 i; i < 8; i++) {
      try this.routerExactOutputExternal(router, pool, zeroForOne, amountOutDesired) returns (
        uint256 used, uint256 out
      ) {
        if (out > 0 && used > 0) return (out, used);
      } catch (bytes memory reason) {
        if (reason.length >= 4 && bytes4(reason) != IMetricOmmSimpleRouter.InvalidSwapDeltas.selector) {
          assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
          }
        }
      }
      amountOutDesired *= 2;
    }
    revert("non-zero tiny swap not found");
  }

  function _trySimulateSwapDeltas(
    address pool,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 bidX64,
    uint128 askX64,
    uint128 priceLimitX64
  ) internal returns (bool ok, int256 a0, int256 a1) {
    try IMetricOmmPool(pool)
      .simulateSwapAndRevert(address(this), zeroForOne, amountSpecified, priceLimitX64, bidX64, askX64, hex"") {
      revert("simulate did not revert");
    } catch (bytes memory reason) {
      if (reason.length < 68) return (false, 0, 0);
      if (bytes4(reason) != IMetricOmmPoolActions.SimulateSwap.selector) return (false, 0, 0);
      assembly ("memory-safe") {
        a0 := mload(add(reason, 36))
        a1 := mload(add(reason, 68))
      }
      ok = true;
    }
  }

  function _randomWalkSwaps(
    MetricOmmSimpleRouter router,
    address pool,
    uint8 token0Decimals,
    uint8 token1Decimals,
    uint256 seed,
    uint8 nSwaps
  ) internal {
    uint256 s = seed;
    for (uint256 i; i < nSwaps; i++) {
      s = uint256(keccak256(abi.encodePacked(s, i, pool)));
      bool zf1 = (s & 1) == 1;
      uint256 lo = _smallTradeAmount(zf1 ? token0Decimals : token1Decimals);
      uint256 hi = 5_000_000 * 10 ** uint256(zf1 ? token0Decimals : token1Decimals);
      uint256 amt = bound(s >> 1, lo, hi);
      if (amt > type(uint128).max / 2) amt = type(uint128).max / 2;
      try this.routerExactInputExternal(router, pool, zf1, amt) returns (uint256) {}
      catch (bytes memory reason) {
        if (reason.length >= 4) {
          bytes4 sel = bytes4(reason);
          if (
            sel != IMetricOmmSimpleRouter.InvalidSwapDeltas.selector
              && sel != IMetricOmmSimpleRouter.InsufficientOutput.selector
          ) {
            assembly ("memory-safe") {
              revert(add(reason, 32), mload(reason))
            }
          }
        }
      }
    }
  }

  function routerExactInputExternal(MetricOmmSimpleRouter router, address pool, bool zeroForOne, uint256 amountIn)
    external
    returns (uint256 amountOut)
  {
    return _routerExactInput(router, pool, zeroForOne, amountIn);
  }

  function routerExactOutputExternal(
    MetricOmmSimpleRouter router,
    address pool,
    bool zeroForOne,
    uint256 amountOutDesired
  ) external returns (uint256 amountInUsed, uint256 amountOut) {
    return _routerExactOutput(router, pool, zeroForOne, amountOutDesired);
  }

  function _routerExactInput(MetricOmmSimpleRouter router, address pool, bool zeroForOne, uint256 amountIn)
    internal
    returns (uint256 amountOut)
  {
    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    return router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: pool,
        tokenIn: zeroForOne ? imm.token0 : imm.token1,
        tokenOut: zeroForOne ? imm.token1 : imm.token0,
        zeroForOne: zeroForOne,
        amountIn: uint128(amountIn),
        amountOutMinimum: 0,
        recipient: address(this),
        deadline: type(uint256).max,
        priceLimitX64: zeroForOne ? uint128(0) : type(uint128).max,
        extensionData: ""
      })
    );
  }

  function _routerExactOutput(MetricOmmSimpleRouter router, address pool, bool zeroForOne, uint256 amountOutDesired)
    internal
    returns (uint256 amountInUsed, uint256 amountOut)
  {
    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    amountInUsed = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: pool,
        tokenIn: zeroForOne ? imm.token0 : imm.token1,
        tokenOut: zeroForOne ? imm.token1 : imm.token0,
        zeroForOne: zeroForOne,
        amountOut: uint128(amountOutDesired),
        amountInMaximum: type(uint128).max,
        recipient: address(this),
        deadline: type(uint256).max,
        priceLimitX64: zeroForOne ? uint128(0) : type(uint128).max,
        extensionData: ""
      })
    );
    amountOut = amountOutDesired;
  }
}
