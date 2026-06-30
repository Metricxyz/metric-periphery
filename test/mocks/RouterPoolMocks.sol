// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {MetricOmmSimpleRouter} from "../../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../../contracts/interfaces/IMetricOmmSimpleRouter.sol";

contract MaliciousPoolForSimpleRouter {
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

  function getImmutables() external view returns (PoolImmutables memory) {
    return PoolImmutables({
      factory: address(0),
      token0: TOKEN0,
      token1: TOKEN1,
      token0ScaleMultiplier: 1,
      token1ScaleMultiplier: 1,
      initialScaledToken0PerShareE18: 1,
      initialScaledToken1PerShareE18: 1,
      minimalMintableLiquidity: 1,
      immutablePriceProvider: address(0),
      lowestBin: 0,
      highestBin: 0,
      extension1: address(0),
      extension2: address(0),
      extension3: address(0),
      extension4: address(0),
      extension5: address(0),
      extension6: address(0),
      extension7: address(0),
      beforeAddLiquidityOrder: 0,
      afterAddLiquidityOrder: 0,
      beforeRemoveLiquidityOrder: 0,
      afterRemoveLiquidityOrder: 0,
      beforeSwapOrder: 0,
      afterSwapOrder: 0
    });
  }

  function swap(address, bool, int128, uint128, bytes calldata callbackData, bytes calldata)
    external
    returns (int128, int128)
  {
    MetricOmmSimpleRouter(payable(msg.sender))
      .metricOmmSwapCallback(int256(AMOUNT0_DELTA), int256(AMOUNT1_DELTA), callbackData);
    return (AMOUNT0_DELTA, AMOUNT1_DELTA);
  }
}

/// @notice Pool that tries nested router swap while a swap is in progress.
contract ReentrantPoolForSimpleRouter {
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  int128 public immutable AMOUNT0_DELTA;
  int128 public immutable AMOUNT1_DELTA;
  bool public nestedAttempted;
  bool public nestedCompleted;

  constructor(address token0, address token1, int128 amount0Delta, int128 amount1Delta) {
    TOKEN0 = token0;
    TOKEN1 = token1;
    AMOUNT0_DELTA = amount0Delta;
    AMOUNT1_DELTA = amount1Delta;
  }

  function getImmutables() external view returns (PoolImmutables memory) {
    return PoolImmutables({
      factory: address(0),
      token0: TOKEN0,
      token1: TOKEN1,
      token0ScaleMultiplier: 1,
      token1ScaleMultiplier: 1,
      initialScaledToken0PerShareE18: 1,
      initialScaledToken1PerShareE18: 1,
      minimalMintableLiquidity: 1,
      immutablePriceProvider: address(0),
      lowestBin: 0,
      highestBin: 0,
      extension1: address(0),
      extension2: address(0),
      extension3: address(0),
      extension4: address(0),
      extension5: address(0),
      extension6: address(0),
      extension7: address(0),
      beforeAddLiquidityOrder: 0,
      afterAddLiquidityOrder: 0,
      beforeRemoveLiquidityOrder: 0,
      afterRemoveLiquidityOrder: 0,
      beforeSwapOrder: 0,
      afterSwapOrder: 0
    });
  }

  function swap(address, bool, int128, uint128, bytes calldata callbackData, bytes calldata)
    external
    returns (int128, int128)
  {
    nestedAttempted = true;
    try MetricOmmSimpleRouter(payable(msg.sender))
      .exactInputSingle(
        IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(this),
        tokenIn: TOKEN0,
        tokenOut: TOKEN1,
        zeroForOne: true,
        amountIn: 1,
        amountOutMinimum: 0,
        recipient: msg.sender,
        deadline: type(uint256).max,
        priceLimitX64: 0,
        extensionData: ""
      })
      ) {
      nestedCompleted = true;
    } catch {}

    MetricOmmSimpleRouter(payable(msg.sender))
      .metricOmmSwapCallback(int256(AMOUNT0_DELTA), int256(AMOUNT1_DELTA), callbackData);
    return (AMOUNT0_DELTA, AMOUNT1_DELTA);
  }
}

/// @notice Pool that returns wrong intermediate output for exact-output multihop tests.
contract WrongOutputPoolForSimpleRouter {
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  int128 public immutable INPUT_DELTA;
  int128 public immutable OUTPUT_DELTA;

  constructor(address token0, address token1, int128 inputDelta, int128 outputDelta) {
    TOKEN0 = token0;
    TOKEN1 = token1;
    INPUT_DELTA = inputDelta;
    OUTPUT_DELTA = outputDelta;
  }

  function getImmutables() external view returns (PoolImmutables memory) {
    return PoolImmutables({
      factory: address(0),
      token0: TOKEN0,
      token1: TOKEN1,
      token0ScaleMultiplier: 1,
      token1ScaleMultiplier: 1,
      initialScaledToken0PerShareE18: 1,
      initialScaledToken1PerShareE18: 1,
      minimalMintableLiquidity: 1,
      immutablePriceProvider: address(0),
      lowestBin: 0,
      highestBin: 0,
      extension1: address(0),
      extension2: address(0),
      extension3: address(0),
      extension4: address(0),
      extension5: address(0),
      extension6: address(0),
      extension7: address(0),
      beforeAddLiquidityOrder: 0,
      afterAddLiquidityOrder: 0,
      beforeRemoveLiquidityOrder: 0,
      afterRemoveLiquidityOrder: 0,
      beforeSwapOrder: 0,
      afterSwapOrder: 0
    });
  }

  function swap(address, bool, int128, uint128, bytes calldata callbackData, bytes calldata)
    external
    returns (int128, int128)
  {
    IMetricOmmSwapCallback(msg.sender).metricOmmSwapCallback(int256(INPUT_DELTA), int256(OUTPUT_DELTA), callbackData);
    return (INPUT_DELTA, OUTPUT_DELTA);
  }
}
