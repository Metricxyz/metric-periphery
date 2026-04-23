// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {FactoryFeeCapsStub} from "../../lib/metric-core/test/FactoryFeeCapsStub.sol";
import {PoolFeeConfig, PoolImmutables} from "@metric-core/types/FactoryStorage.sol";

/// @notice Minimal factory stub so `MetricOmmSwapRouter` and liquidity callbacks can resolve pool tokens.
contract RouterTestFactory is FactoryFeeCapsStub {
  function getTokens(address pool) external view returns (address token0, address token1) {
    PoolImmutables memory imm = poolImmutables[pool];
    return (imm.token0, imm.token1);
  }

  function registerPool(
    address pool,
    PoolImmutables calldata imm,
    PoolFeeConfig calldata fees,
    address adminFeeDest,
    address admin_
  ) external {
    poolImmutables[pool] = imm;
    poolFeeConfig[pool] = fees;
    poolAdminFeeDestination[pool] = adminFeeDest;
    poolAdmin[pool] = admin_;
    priceProviderTimelock[pool] = type(uint256).max;
  }
}
