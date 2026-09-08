// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {IPriceVelocityGuardExtension} from "../interfaces/extensions/IPriceVelocityGuardExtension.sol";
import {BaseMetricExtension} from "./base/BaseMetricExtension.sol";

/// @title PriceVelocityGuardExtension
/// @notice Caps how fast the provided price can move between blocks, per pool.
/// @dev This extension allows the pool admin to increase security of the pool by limiting price
///      manipulation through velocity constraints. However, it assumes that the pool admin is not
///      an adversary and acts to optimize pool profitability. The pool admin must be trusted.
///
///      Allowed deviation scales as `maxChangePerBlockE18 * sqrt(1 + blockDifference)`.
///      Comparison is performed on squares to avoid an on-chain sqrt:
///        changeE18^2 <= maxChangePerBlockE18^2 * (1 + blockDiff)
///      where 1e18 = 100% (full unit).
///
///      Per-block budget: `anchorMidPriceX64` is the check reference and stays fixed until a swap
///      lands in a block after `lastObservedBlock`. `blockDiff` is measured from `anchorBlock`, not
///      from the swap's own block, so every swap checked against the same anchor gets the same
///      allowance regardless of how many swaps already landed in that block.
contract PriceVelocityGuardExtension is BaseMetricExtension, IPriceVelocityGuardExtension {
  mapping(address pool => PriceVelocityState) public priceVelocityState;

  constructor(address factory_) BaseMetricExtension(factory_) {}

  function setMaxChangePerBlock(address pool_, uint64 newMaxPctChangePerBlockE18) external onlyPoolAdmin(pool_) {
    priceVelocityState[pool_].maxChangePerBlockE18 = newMaxPctChangePerBlockE18;
    emit MaxChangePerBlockSet(pool_, newMaxPctChangePerBlockE18);
  }

  function setAnchorMidPrice(address pool_, uint128 newAnchorMidPriceX64) external onlyPoolAdmin(pool_) {
    PriceVelocityState storage s = priceVelocityState[pool_];
    s.anchorMidPriceX64 = newAnchorMidPriceX64;
    s.lastObservedMidPriceX64 = newAnchorMidPriceX64;
    s.anchorBlock = uint64(block.number);
    s.lastObservedBlock = uint64(block.number);
    emit AnchorMidPriceUpdated(pool_, newAnchorMidPriceX64);
  }

  function beforeSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint128,
    uint128,
    uint128 referencePriceX64,
    bytes calldata
  ) external override returns (bytes4) {
    // onlyPool omitted: state is keyed by msg.sender, so a non-pool caller cannot affect another pool.
    address pool_ = msg.sender;
    // Pool passes `referencePriceX64` as the mid/price-path anchor from `getQuote()`.
    uint128 midPrice = referencePriceX64;

    PriceVelocityState storage s = priceVelocityState[pool_];
    uint128 anchorMid = s.anchorMidPriceX64;

    if (anchorMid == 0) {
      s.anchorMidPriceX64 = midPrice;
      s.anchorBlock = uint64(block.number);
      s.lastObservedMidPriceX64 = midPrice;
      s.lastObservedBlock = uint64(block.number);
      return IMetricOmmExtensions.beforeSwap.selector;
    }

    if (block.number > s.lastObservedBlock) {
      // Left the last-observed block behind: roll the anchor to that block's final mid.
      anchorMid = s.lastObservedMidPriceX64;
      s.anchorMidPriceX64 = anchorMid;
      s.anchorBlock = s.lastObservedBlock;
    }

    uint256 blockDiff = block.number - s.anchorBlock;

    uint64 maxChange = s.maxChangePerBlockE18;
    if (maxChange != 0) {
      uint256 delta = midPrice > anchorMid ? uint256(midPrice - anchorMid) : uint256(anchorMid - midPrice);
      uint256 changeE18 = (delta * 1e18) / uint256(anchorMid);
      uint256 actualSq = changeE18 * changeE18;
      uint256 allowedSq = uint256(maxChange) * uint256(maxChange) * (1 + blockDiff);
      if (actualSq > allowedSq) {
        revert PriceVelocityExceeded(actualSq, allowedSq);
      }
    }

    s.lastObservedMidPriceX64 = midPrice;
    s.lastObservedBlock = uint64(block.number);

    return IMetricOmmExtensions.beforeSwap.selector;
  }
}
