// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceVelocityGuardExtension
/// @notice Per-pool oracle mid-price velocity guard admin and read API.
interface IPriceVelocityGuardExtension {
  struct PriceVelocityState {
    /// @dev Velocity check reference for the current interaction block. Fixed for all swaps in the block.
    uint128 anchorMidPriceX64;
    /// @dev Mid from the latest swap; becomes the next block's anchor.
    uint128 lastObservedMidPriceX64;
    uint64 lastInteractionBlock;
    uint64 maxChangePerBlockE18;
  }

  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxChangePerBlockSet(address indexed pool, uint64 newMaxPctChangePerBlockE18);
  event AnchorMidPriceUpdated(address indexed pool, uint128 newAnchorMidPriceX64);

  function setMaxChangePerBlock(address pool, uint64 newMaxPctChangePerBlockE18) external;

  function setAnchorMidPrice(address pool, uint128 newAnchorMidPriceX64) external;
}
