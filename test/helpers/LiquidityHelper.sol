// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "@metric-core/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";

/// @notice Adds liquidity via `addLiquidity` + modify-liquidity callback.
contract LiquidityHelper is IMetricOmmModifyLiquidityCallback {
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
    if (amount0Delta > 0) {
      IERC20(imm.token0).safeTransfer(msg.sender, amount0Delta);
    }
    if (amount1Delta > 0) {
      IERC20(imm.token1).safeTransfer(msg.sender, amount1Delta);
    }
  }
}
