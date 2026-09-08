// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceVelocityGuardExtension
/// @notice Per-pool oracle mid-price velocity guard admin and read API.
interface IPriceVelocityGuardExtension {
  struct PriceVelocityState {
    /// @dev Velocity check reference. Fixed until a swap lands in a block after `lastObservedBlock`.
    uint128 anchorMidPriceX64;
    /// @dev Mid from the latest swap; becomes the next anchor once its block is left behind.
    uint128 lastObservedMidPriceX64;
    /// @dev Block number `anchorMidPriceX64` was observed in; blockDiff is measured from here.
    uint64 anchorBlock;
    /// @dev Block number of the latest swap.
    uint64 lastObservedBlock;
    uint64 maxChangePerBlockE18;
  }

  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxChangePerBlockSet(address indexed pool, uint64 newMaxPctChangePerBlockE18);
  event AnchorMidPriceUpdated(address indexed pool, uint128 newAnchorMidPriceX64);

  function setMaxChangePerBlock(address pool, uint64 newMaxPctChangePerBlockE18) external;

  function setAnchorMidPrice(address pool, uint128 newAnchorMidPriceX64) external;
}
