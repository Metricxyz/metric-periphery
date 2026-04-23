// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

contract MetricOmmPoolQuoter {
  using SafeCast for int256;
  error WrappedError(address target, bytes4 selector, bytes reason, bytes additionalInfo);

  ///@return amount0Delta The amount of token0 that would be sent (negative) or received (positive) by the pool
  ///@return amount1Delta The amount of token1 that would be sent (negative) or received (positive) by the pool
  function quoteSwap(
    address pool,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPool(pool)
      .simulateSwapAndRevert(zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64) {
      // This should not happen as simulateSwapAndRevert always reverts
      revert("SimulateSwapAndRevert did not revert");
    } catch (bytes memory reason) {
      // forge-lint: disable-next-line(unsafe-typecast)
      if (bytes4(reason) == IMetricOmmPoolActions.SimulateSwap.selector) {
        int256 a0;
        int256 a1;
        assembly {
          a0 := mload(add(reason, 36))
          a1 := mload(add(reason, 68))
        }
        amount0Delta = a0.toInt128();
        amount1Delta = a1.toInt128();
        return (amount0Delta, amount1Delta);
      } else {
        // Bubble up the error
        revert WrappedError(pool, IMetricOmmPoolActions.simulateSwapAndRevert.selector, reason, "");
      }
    }
  }
}
