// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IPriceProviderSwapReporter} from "@metric-core/interfaces/IPriceProvider/IPriceProviderSwapReporter.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {PoolSlot0} from "@metric-core/types/HookTypes.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {SubhookUtils} from "../base/SubhookUtils.sol";

/// @title SwapReporterSubhook
/// @notice Best-effort post-swap reporting to the pool's active price provider.
abstract contract SwapReporterSubhook is SubhookUtils {
  function subhookPermissions() internal pure virtual override returns (uint16) {
    return MetricHooks.AFTER_SWAP_FLAG;
  }

  function _afterSwapReport(
    address pool_,
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Final,
    int128 amount0Delta,
    int128 amount1Delta
  ) internal {
    PoolSlot0 memory slot0Final = Slot0Library.unpack(packedSlot0Final);
    address priceProvider = _resolvedPriceProvider(pool_);
    if (priceProvider == address(0)) return;

    try IPriceProviderSwapReporter(priceProvider)
      .reportSwap(
        sender,
        recipient,
        zeroForOne,
        amountSpecified,
        priceLimitX64,
        amount0Delta,
        amount1Delta,
        slot0Final.curBinIdx,
        slot0Final.curPosInBin
      ) {}
      catch (bytes memory) {}
  }
}
