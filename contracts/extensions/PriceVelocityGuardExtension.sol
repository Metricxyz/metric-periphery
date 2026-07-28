// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "@metric-core/interfaces/extensions/IMetricOmmExtensions.sol";
import {SwapMath} from "@metric-core/libraries/SwapMath.sol";
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
///      Per-block budget: `anchorMidPriceX64` is the check reference and stays fixed for every swap in
///      the current block. `lastObservedMidPriceX64` tracks the latest swap mid and only becomes
///      the new anchor when the block changes — so the first swap cannot widen the ceiling for
///      later swaps in the same block.
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
    s.lastInteractionBlock = uint64(block.number);
    emit AnchorMidPriceUpdated(pool_, newAnchorMidPriceX64);
  }

  function beforeSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata
  ) external override returns (bytes4) {
    address pool_ = msg.sender;
    (uint256 midPriceX64,) = SwapMath.midAndSpreadFeeX64FromBidAsk(uint256(bidPriceX64), uint256(askPriceX64));
    // casting to `uint128` is safe: geometric mid of two uint128 bid/ask quotes fits uint128 (same bound as pool)
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 midPrice = uint128(midPriceX64);

    PriceVelocityState storage s = priceVelocityState[pool_];
    uint128 anchorMid = s.anchorMidPriceX64;
    uint64 prevBlock = s.lastInteractionBlock;

    if (anchorMid == 0) {
      s.anchorMidPriceX64 = midPrice;
      s.lastObservedMidPriceX64 = midPrice;
      s.lastInteractionBlock = uint64(block.number);
      return IMetricOmmExtensions.beforeSwap.selector;
    }

    uint256 blockDiff;
    if (block.number != prevBlock) {
      // New block: anchor to the previous block's last mid, not this swap's mid.
      anchorMid = s.lastObservedMidPriceX64;
      blockDiff = block.number - prevBlock;
      s.anchorMidPriceX64 = anchorMid;
      s.lastInteractionBlock = uint64(block.number);
    } else {
      blockDiff = 0;
    }

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

    return IMetricOmmExtensions.beforeSwap.selector;
  }
}
