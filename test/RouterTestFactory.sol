// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {FactoryFeeCapsStub} from "../lib/metric-core/test/FactoryFeeCapsStub.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";

/// @notice Minimal factory stub for tests that need fee config and admin lookups.
contract RouterTestFactory is FactoryFeeCapsStub {
  mapping(address => bool) public isPool;

  function registerPool(address pool, PoolFeeConfig calldata fees, address adminFeeDest, address admin_) external {
    poolFeeConfig[pool] = fees;
    poolAdminFeeDestination[pool] = adminFeeDest;
    poolAdmin[pool] = admin_;
    priceProviderTimelock[pool] = type(uint256).max;
    isPool[pool] = true;
  }
}
