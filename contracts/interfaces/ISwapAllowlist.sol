// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {ISwapAllowlistProvider} from "@metric-core/interfaces/ISwapAllowlistProvider.sol";

/// @title ISwapAllowlist
/// @notice Full API for the periphery `SwapAllowlist` implementation: pool queries plus pool-admin configuration.
interface ISwapAllowlist is ISwapAllowlistProvider {
  /// @notice Allow or deny `swapper` for swaps on `pool`. Callable only by that pool's factory admin.
  function setAllowedToSwap(address pool, address swapper, bool allowed) external;
}
