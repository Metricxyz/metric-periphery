// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Batch bin decode helper to keep MetricOmmPoolStateView.binStates stack shallow under via-IR.
library StateViewBinBatch {
  using SafeCast for uint256;

  struct Row {
    uint104 token0BalanceScaled;
    uint104 token1BalanceScaled;
    uint16 lengthE6;
    uint16 addFeeBuyE6;
    uint16 addFeeSellE6;
    uint104 totalShares;
  }

  function decode(bytes32[] memory states, bytes32[] memory sharesRaw)
    internal
    pure
    returns (
      uint104[] memory token0BalancesScaled,
      uint104[] memory token1BalancesScaled,
      uint16[] memory lengthsInUnits,
      uint16[] memory addFeeBuysE6,
      uint16[] memory addFeeSellsE6,
      uint104[] memory totalShares
    )
  {
    uint256 len = states.length;
    token0BalancesScaled = new uint104[](len);
    token1BalancesScaled = new uint104[](len);
    lengthsInUnits = new uint16[](len);
    addFeeBuysE6 = new uint16[](len);
    addFeeSellsE6 = new uint16[](len);
    totalShares = new uint104[](len);

    for (uint256 i = 0; i < len; ++i) {
      Row memory row = _row(states[i], sharesRaw[i]);
      token0BalancesScaled[i] = row.token0BalanceScaled;
      token1BalancesScaled[i] = row.token1BalanceScaled;
      lengthsInUnits[i] = row.lengthE6;
      addFeeBuysE6[i] = row.addFeeBuyE6;
      addFeeSellsE6[i] = row.addFeeSellE6;
      totalShares[i] = row.totalShares;
    }
  }

  function _row(bytes32 state, bytes32 sharesRaw) private pure returns (Row memory row) {
    (row.token0BalanceScaled, row.token1BalanceScaled, row.lengthE6, row.addFeeBuyE6, row.addFeeSellE6) =
      PoolStateLibrary._decodeBinState(state);
    row.totalShares = PoolStateLibrary._decodeBinTotalShares(sharesRaw).toUint104();
  }
}
