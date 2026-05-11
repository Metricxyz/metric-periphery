// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {ISwapAllowlistProvider} from "@metric-core/interfaces/ISwapAllowlistProvider.sol";
import {ISwapAllowlist} from "./interfaces/ISwapAllowlist.sol";

/// @title SwapAllowlist
/// @notice Pool-scoped swap allowlist managed by each pool admin (admin address is on the factory)
contract SwapAllowlist is ISwapAllowlist {
  address public immutable FACTORY;

  mapping(address => mapping(address => bool)) internal _allowedToSwap;

  error OnlyPoolAdmin(address pool, address caller, address admin);
  event AllowedToSwapSet(address indexed pool, address indexed swapper, bool allowed);

  constructor(address factory) {
    FACTORY = factory;
  }

  /// @inheritdoc ISwapAllowlistProvider
  function isAllowedToSwap(address swapper) external view override returns (bool) {
    return _allowedToSwap[msg.sender][swapper];
  }

  /// @inheritdoc ISwapAllowlistProvider
  function isAllowedToSwap(address pool, address swapper) external view override returns (bool) {
    return _allowedToSwap[pool][swapper];
  }

  /// @inheritdoc ISwapAllowlist
  function setAllowedToSwap(address pool, address swapper, bool allowed) external override {
    address poolAdmin = IMetricOmmPoolFactory(FACTORY).poolAdmin(pool);
    if (msg.sender != poolAdmin) revert OnlyPoolAdmin(pool, msg.sender, poolAdmin);
    _allowedToSwap[pool][swapper] = allowed;
    emit AllowedToSwapSet(pool, swapper, allowed);
  }
}
