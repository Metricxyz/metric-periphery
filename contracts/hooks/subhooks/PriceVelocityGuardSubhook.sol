// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {SwapOracleSnapshot} from "@metric-core/types/HookTypes.sol";
import {MetricFactorySubhook} from "../base/MetricFactorySubhook.sol";

/// @title PriceVelocityGuardSubhook
/// @notice Caps how fast the provided price can move between blocks.
/// @dev This hook allows the pool admin to increase security of the pool by limiting price
///      manipulation through velocity constraints. However, it assumes that the pool admin is not
///      an adversary and acts to optimize pool profitability. The pool admin must be trusted.
///
///      Allowed deviation scales as `maxPctChangePerBlockE18 * sqrt(1 + blockDifference)`.
///      Comparison is performed on squares to avoid an on-chain sqrt:
///        deltaE18^2 <= maxPctChangePerBlockE18^2 * (1 + blockDiff)
abstract contract PriceVelocityGuardSubhook is MetricFactorySubhook {
  uint128 public lastMidPriceX64;
  uint64 public lastUpdateBlock;
  uint128 public maxPctChangePerBlockE18;

  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxPctChangePerBlockSet(uint128 newMaxPctChangePerBlockE18);
  event LastMidPriceUpdated(uint128 newLastMidPriceX64);

  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.BEFORE_SWAP_FLAG;
  }

  function setMaxPctChangePerBlock(uint128 newMaxPctChangePerBlockE18) external {
    _onlyPoolAdmin();
    maxPctChangePerBlockE18 = newMaxPctChangePerBlockE18;
    emit MaxPctChangePerBlockSet(newMaxPctChangePerBlockE18);
  }

  function setLastMidPrice(uint128 newLastMidPriceX64) external {
    _onlyPoolAdmin();
    lastMidPriceX64 = newLastMidPriceX64;
    lastUpdateBlock = uint64(block.number);
    emit LastMidPriceUpdated(newLastMidPriceX64);
  }

  function _beforeSwapPriceVelocity(SwapOracleSnapshot calldata oracle) internal {
    uint128 midPrice = (oracle.bidPriceX64 + oracle.askPriceX64) / 2;

    uint128 prevMid = lastMidPriceX64;
    uint64 prevBlock = lastUpdateBlock;

    lastMidPriceX64 = midPrice;
    lastUpdateBlock = uint64(block.number);

    if (prevMid == 0) return;

    uint128 maxPct = maxPctChangePerBlockE18;
    if (maxPct == 0) return;

    uint256 blockDiff = block.number - prevBlock;

    uint256 delta = midPrice > prevMid ? uint256(midPrice - prevMid) : uint256(prevMid - midPrice);

    uint256 pctChangeE18 = (delta * 1e18) / uint256(prevMid);

    uint256 actualSq = pctChangeE18 * pctChangeE18;
    uint256 allowedSq = uint256(maxPct) * uint256(maxPct) * (1 + blockDiff);

    if (actualSq > allowedSq) {
      revert PriceVelocityExceeded(actualSq, allowedSq);
    }
  }
}
