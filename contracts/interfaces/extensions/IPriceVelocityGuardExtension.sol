// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceVelocityGuardExtension
/// @notice Per-pool oracle mid-price velocity guard admin and read API.
interface IPriceVelocityGuardExtension {
  struct PriceVelocityState {
    uint128 lastMidPriceX64;
    uint64 lastUpdateBlock;
    uint64 maxChangePerBlockE18;
  }

  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxChangePerBlockSet(address indexed pool, uint64 newMaxPctChangePerBlockE18);
  event LastMidPriceUpdated(address indexed pool, uint128 newLastMidPriceX64);

  function setMaxChangePerBlock(address pool, uint64 newMaxPctChangePerBlockE18) external;

  function setLastMidPrice(address pool, uint128 newLastMidPriceX64) external;
}
