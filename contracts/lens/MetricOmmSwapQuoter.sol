// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {IMetricOmmSwapQuoter} from "../interfaces/IMetricOmmSwapQuoter.sol";
import {MetricOmmSwapInputs} from "../libraries/MetricOmmSwapInputs.sol";
import {MetricOmmSwapResults} from "../libraries/MetricOmmSwapResults.sol";
import {MetricOmmSwapPath} from "../libraries/MetricOmmSwapPath.sol";
import {MetricOmmSwapQuoteDecode} from "../libraries/MetricOmmSwapQuoteDecode.sol";

contract MetricOmmSwapQuoter is IMetricOmmSwapQuoter {
  // ============ External: live quotes (single hop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactInSingle(address pool, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteLiveExactInSingle(pool, address(this), zeroForOne, amountIn, priceLimitX64, hex"");
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactInSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteLiveSwap(
      pool, recipient, zeroForOne, MetricOmmSwapInputs.asAmountSpecifiedIn(amountIn), priceLimitX64, extensionData
    );
    return MetricOmmSwapResults.extractAmountInAndOut(zeroForOne, amount0Delta, amount1Delta);
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactOutSingle(address pool, bool zeroForOne, uint128 amountOutDesired, uint128 priceLimitX64)
    external
    returns (uint256, uint256)
  {
    return quoteLiveExactOutSingle(pool, address(this), zeroForOne, amountOutDesired, priceLimitX64, hex"");
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactOutSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) public returns (uint256, uint256) {
    priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteLiveSwap(
      pool,
      recipient,
      zeroForOne,
      MetricOmmSwapInputs.asAmountSpecifiedOut(amountOutDesired),
      priceLimitX64,
      extensionData
    );
    return MetricOmmSwapResults.extractAmountInAndOut(zeroForOne, amount0Delta, amount1Delta);
  }

  // ============ External: live quotes (multihop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactIn(QuoteExactInputParams calldata params) external returns (uint256, uint256) {
    _validateQuotePath(params.pools, params.extensionDatas, params.zeroForOneBitMap);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountIn;

    for (uint256 i = 0; i <= last; i++) {
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, i);
      (uint256 hopAmountIn, uint256 hopAmountOut) = quoteLiveExactInSingle(
        params.pools[i],
        address(this),
        zeroForOne,
        amount,
        MetricOmmSwapPath.openLimit(zeroForOne),
        params.extensionDatas[i]
      );
      // casting to 'uint8' is safe because '_validateQuotePath' above caps 'pools.length' at
      // 'MetricOmmSwapPath.MAX_PATH_POOLS' (256), so 'i <= last' never exceeds 255
      // forge-lint: disable-next-line(unsafe-typecast)
      if (hopAmountIn < amount) revert InvalidInputAmountAtHop(uint8(i), hopAmountIn, amount);
      if (i == last) return (params.amountIn, hopAmountOut);
      amount = MetricOmmSwapInputs.toUint128(hopAmountOut);
    }

    revert InvalidSwapDeltas();
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactOut(QuoteExactOutputParams calldata params)
    external
    returns (uint256 amountIn, uint256 amountOut)
  {
    _validateQuotePath(params.pools, params.extensionDatas, params.zeroForOneBitMap);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountOut;
    amountOut = params.amountOut;

    for (uint256 i = last + 1; i > 0; i--) {
      uint256 hop = i - 1;
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, hop);
      (uint256 hopAmountIn, uint256 hopAmountOut) = quoteLiveExactOutSingle(
        params.pools[hop],
        address(this),
        zeroForOne,
        amount,
        MetricOmmSwapPath.openLimit(zeroForOne),
        params.extensionDatas[hop]
      );
      // casting to 'uint8' is safe because '_validateQuotePath' above caps 'pools.length' at
      // 'MetricOmmSwapPath.MAX_PATH_POOLS' (256), so 'hop <= last' never exceeds 255
      // forge-lint: disable-next-line(unsafe-typecast)
      if (hopAmountOut != amount) revert InvalidOutputAmountAtHop(uint8(hop), hopAmountOut, amount);
      if (hop == 0) {
        amountIn = hopAmountIn;
        return (amountIn, amountOut);
      }
      amount = MetricOmmSwapInputs.toUint128(hopAmountIn);
    }

    revert InvalidSwapDeltas();
  }

  // ============ External: hypothetical quotes (single hop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactInputSingle(
    address pool,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) external returns (uint256, uint256) {
    return quoteHypotheticalExactInputSingle(
      pool, msg.sender, zeroForOne, amountIn, priceLimitX64, bidPriceX64, askPriceX64, referencePriceX64, hex""
    );
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactInputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes memory extensionData
  ) public virtual returns (uint256, uint256) {
    priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteSwap(
      pool,
      recipient,
      zeroForOne,
      MetricOmmSwapInputs.asAmountSpecifiedIn(amountIn),
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );
    return MetricOmmSwapResults.extractAmountInAndOut(zeroForOne, amount0Delta, amount1Delta);
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactOutputSingle(
    address pool,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) external returns (uint256, uint256) {
    return quoteHypotheticalExactOutputSingle(
      pool, msg.sender, zeroForOne, amountOutDesired, priceLimitX64, bidPriceX64, askPriceX64, referencePriceX64, hex""
    );
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactOutputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes memory extensionData
  ) public virtual returns (uint256, uint256) {
    priceLimitX64 = MetricOmmSwapPath.normalizePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteSwap(
      pool,
      recipient,
      zeroForOne,
      MetricOmmSwapInputs.asAmountSpecifiedOut(amountOutDesired),
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );
    return MetricOmmSwapResults.extractAmountInAndOut(zeroForOne, amount0Delta, amount1Delta);
  }

  // ============ External: hypothetical quotes (multihop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactInput(QuoteHypotheticalExactInputParams calldata params)
    external
    returns (uint256 totalIn, uint256 totalOut)
  {
    _validateQuotePath(params.pools, params.extensionDatas, params.zeroForOneBitMap);
    _validateHypotheticalPrices(
      params.pools.length, params.bidPricesX64, params.askPricesX64, params.referencePricesX64
    );

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountIn;

    for (uint256 i = 0; i <= last; i++) {
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, i);
      (uint256 hopAmountIn, uint256 hopAmountOut) = quoteHypotheticalExactInputSingle(
        params.pools[i],
        address(this),
        zeroForOne,
        amount,
        MetricOmmSwapPath.openLimit(zeroForOne),
        params.bidPricesX64[i],
        params.askPricesX64[i],
        params.referencePricesX64[i],
        params.extensionDatas[i]
      );
      // casting to 'uint8' is safe because '_validateQuotePath' above caps 'pools.length' at
      // 'MetricOmmSwapPath.MAX_PATH_POOLS' (256), so 'i <= last' never exceeds 255
      // forge-lint: disable-next-line(unsafe-typecast)
      if (hopAmountIn < amount) revert InvalidInputAmountAtHop(uint8(i), hopAmountIn, amount);
      if (i == last) return (params.amountIn, hopAmountOut);
      amount = MetricOmmSwapInputs.toUint128(hopAmountOut);
    }

    revert InvalidSwapDeltas();
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactOutput(QuoteHypotheticalExactOutputParams calldata params)
    external
    returns (uint256 amountIn, uint256 amountOut)
  {
    _validateQuotePath(params.pools, params.extensionDatas, params.zeroForOneBitMap);
    _validateHypotheticalPrices(
      params.pools.length, params.bidPricesX64, params.askPricesX64, params.referencePricesX64
    );

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountOut;
    amountOut = params.amountOut;

    for (uint256 i = last + 1; i > 0; i--) {
      uint256 hop = i - 1;
      bool zeroForOne = MetricOmmSwapPath.resolveZeroForOneBitmap(params.zeroForOneBitMap, hop);
      (uint256 hopAmountIn, uint256 hopAmountOut) = quoteHypotheticalExactOutputSingle(
        params.pools[hop],
        address(this),
        zeroForOne,
        amount,
        MetricOmmSwapPath.openLimit(zeroForOne),
        params.bidPricesX64[hop],
        params.askPricesX64[hop],
        params.referencePricesX64[hop],
        params.extensionDatas[hop]
      );
      // casting to 'uint8' is safe because '_validateQuotePath' above caps 'pools.length' at
      // 'MetricOmmSwapPath.MAX_PATH_POOLS' (256), so 'hop <= last' never exceeds 255
      // forge-lint: disable-next-line(unsafe-typecast)
      if (hopAmountOut != amount) revert InvalidOutputAmountAtHop(uint8(hop), hopAmountOut, amount);
      if (hop == 0) {
        amountIn = hopAmountIn;
        return (amountIn, amountOut);
      }
      amount = MetricOmmSwapInputs.toUint128(hopAmountIn);
    }

    revert InvalidSwapDeltas();
  }

  // ============ Internal: quote orchestration ============

  /// @dev Resolves the pool's active price provider the same way `MetricOmmPool._resolvedPriceProvider()` does:
  ///      the immutable provider if set, otherwise the mutable one read from pool storage via EXTSLOAD.
  function _resolveLivePricesX64(address pool)
    internal
    returns (uint128 bidPriceX64, uint128 askPriceX64, uint128 referencePriceX64)
  {
    address provider = IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
    if (provider == address(0)) provider = PoolStateLibrary._slot3(pool);
    if (provider == address(0)) revert InvalidPriceProvider();
    (bidPriceX64, askPriceX64, referencePriceX64) = IPriceProvider(provider).getQuote();
  }

  function _quoteLiveSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    (uint128 bidPriceX64, uint128 askPriceX64, uint128 referencePriceX64) = _resolveLivePricesX64(pool);
    return _quoteSwap(
      pool,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );
  }

  function _quoteSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPoolActions(pool)
      .simulateSwapAndRevert(
        recipient,
        zeroForOne,
        amountSpecified,
        priceLimitX64,
        bidPriceX64,
        askPriceX64,
        referencePriceX64,
        extensionData
      ) {
      revert QuoteDidNotRevert();
    } catch (bytes memory reason) {
      bool matched;
      (amount0Delta, amount1Delta, matched) =
        MetricOmmSwapQuoteDecode.decodeSwapDeltas(reason, IMetricOmmPoolActions.SimulateSwap.selector);
      if (matched) return (amount0Delta, amount1Delta);
      revert WrappedError(pool, IMetricOmmPoolActions.simulateSwapAndRevert.selector, reason);
    }
  }

  function _validateQuotePath(address[] calldata pools, bytes[] calldata extensionDatas, uint256 zeroForOneBitMap)
    internal
    view
  {
    if (pools.length == 0 || extensionDatas.length != pools.length || pools.length > MetricOmmSwapPath.MAX_PATH_POOLS) {
      revert InvalidPath();
    }
    if (pools.length > 1 && !MetricOmmSwapPath.poolsAreConnected(pools, zeroForOneBitMap)) {
      revert InvalidPath();
    }
  }

  function _validateHypotheticalPrices(
    uint256 poolCount,
    uint128[] calldata bidPricesX64,
    uint128[] calldata askPricesX64,
    uint128[] calldata referencePricesX64
  ) internal pure {
    if (bidPricesX64.length != poolCount || askPricesX64.length != poolCount || referencePricesX64.length != poolCount)
    {
      revert InvalidPath();
    }
  }
}
