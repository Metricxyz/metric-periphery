// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";

/// @title PriceVelocityGuardSubhook
/// @notice Caps how fast the provided price can move between blocks, per pool.
/// @dev This hook allows the pool admin to increase security of the pool by limiting price
///      manipulation through velocity constraints. However, it assumes that the pool admin is not
///      an adversary and acts to optimize pool profitability. The pool admin must be trusted.
///
///      Allowed deviation scales as `maxChangePerBlockE18 * sqrt(1 + blockDifference)`.
///      Comparison is performed on squares to avoid an on-chain sqrt:
///        changeE18^2 <= maxChangePerBlockE18^2 * (1 + blockDiff)
///      where 1e18 = 100% (full unit).
abstract contract PriceVelocityGuardSubhook is SubhookUtils {
  struct PriceVelocityState {
    uint128 lastMidPriceX64;
    uint64 lastUpdateBlock;
    uint64 maxChangePerBlockE18;
  }

  mapping(address pool => PriceVelocityState) public priceVelocityState;

  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxChangePerBlockSet(address indexed pool, uint64 newMaxPctChangePerBlockE18);
  event LastMidPriceUpdated(address indexed pool, uint128 newLastMidPriceX64);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_SWAP_FLAG;
  }

  function setMaxChangePerBlock(address pool_, uint64 newMaxPctChangePerBlockE18) external {
    _onlyPoolAdmin(pool_);
    priceVelocityState[pool_].maxChangePerBlockE18 = newMaxPctChangePerBlockE18;
    emit MaxChangePerBlockSet(pool_, newMaxPctChangePerBlockE18);
  }

  function setLastMidPrice(address pool_, uint128 newLastMidPriceX64) external {
    _onlyPoolAdmin(pool_);
    PriceVelocityState storage s = priceVelocityState[pool_];
    s.lastMidPriceX64 = newLastMidPriceX64;
    s.lastUpdateBlock = uint64(block.number);
    emit LastMidPriceUpdated(pool_, newLastMidPriceX64);
  }

  function _beforeSwapPriceVelocity(address pool_, SwapOracleSnapshot calldata oracle) internal {
    uint128 midPrice = (oracle.bidPriceX64 + oracle.askPriceX64) / 2;

    PriceVelocityState storage s = priceVelocityState[pool_];
    uint128 prevMid = s.lastMidPriceX64;
    uint64 prevBlock = s.lastUpdateBlock;

    s.lastMidPriceX64 = midPrice;
    s.lastUpdateBlock = uint64(block.number);

    if (prevMid == 0) return;

    uint64 maxChange = s.maxChangePerBlockE18;
    if (maxChange == 0) return;

    uint256 blockDiff = block.number - prevBlock;

    uint256 delta = midPrice > prevMid ? uint256(midPrice - prevMid) : uint256(prevMid - midPrice);

    uint256 changeE18 = (delta * 1e18) / uint256(prevMid);

    uint256 actualSq = changeE18 * changeE18;
    uint256 allowedSq = uint256(maxChange) * uint256(maxChange) * (1 + blockDiff);

    if (actualSq > allowedSq) {
      revert PriceVelocityExceeded(actualSq, allowedSq);
    }
  }
}
