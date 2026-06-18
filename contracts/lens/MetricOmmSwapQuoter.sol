// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IMetricOmmSwapQuoter} from "../interfaces/IMetricOmmSwapQuoter.sol";

contract MetricOmmSwapQuoter is IMetricOmmSwapQuoter {
  uint128 private constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);
  uint256 private constant MAX_PATH_POOLS = uint256(type(uint8).max) + 1;

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
    return _quoteLiveExactInSingle(pool, recipient, zeroForOne, amountIn, priceLimitX64, extensionData);
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
    return _quoteLiveExactOutSingle(pool, recipient, zeroForOne, amountOutDesired, priceLimitX64, extensionData);
  }

  // ============ External: live quotes (multihop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactIn(QuoteExactInputParams calldata params) external returns (uint256, uint256) {
    _validateQuotePath(params.pools, params.extensionDatas);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountIn;

    for (uint256 i = 0; i <= last; i++) {
      bool zeroForOne = _resolveZeroForOneBitmap(params.zeroForOneBitMap, i);
      (uint256 hopAmountIn, uint256 hopAmountOut) = _quoteLiveExactInSingle(
        params.pools[i], address(this), zeroForOne, amount, _openLimit(zeroForOne), params.extensionDatas[i]
      );
      if (hopAmountIn < amount) revert InvalidInputAmountAtHop(uint8(i), hopAmountIn, amount);
      if (i == last) return (params.amountIn, hopAmountOut);
      amount = _toUint128(hopAmountOut);
    }

    revert InvalidSwapDeltas();
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteLiveExactOut(QuoteExactOutputParams calldata params)
    external
    returns (uint256 amountIn, uint256 amountOut)
  {
    _validateQuotePath(params.pools, params.extensionDatas);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountOut;
    amountOut = params.amountOut;

    for (uint256 i = last + 1; i > 0; i--) {
      uint256 hop = i - 1;
      bool zeroForOne = _resolveZeroForOneBitmap(params.zeroForOneBitMap, hop);
      (uint256 hopAmountIn, uint256 hopAmountOut) = _quoteLiveExactOutSingle(
        params.pools[hop], address(this), zeroForOne, amount, _openLimit(zeroForOne), params.extensionDatas[hop]
      );
      if (hopAmountOut != amount) revert InvalidOutputAmountAtHop(uint8(hop), hopAmountOut, amount);
      if (hop == 0) {
        amountIn = hopAmountIn;
        return (amountIn, amountOut);
      }
      amount = _toUint128(hopAmountIn);
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
    uint128 askPriceX64
  ) external returns (uint256, uint256) {
    return quoteHypotheticalExactInputSingle(
      pool, msg.sender, zeroForOne, amountIn, priceLimitX64, bidPriceX64, askPriceX64, hex""
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
    bytes memory extensionData
  ) public virtual returns (uint256, uint256) {
    return _quoteHypotheticalExactInputSingle(
      pool, recipient, zeroForOne, amountIn, priceLimitX64, bidPriceX64, askPriceX64, extensionData
    );
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactOutputSingle(
    address pool,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64
  ) external returns (uint256, uint256) {
    return quoteHypotheticalExactOutputSingle(
      pool, msg.sender, zeroForOne, amountOutDesired, priceLimitX64, bidPriceX64, askPriceX64, hex""
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
    bytes memory extensionData
  ) public virtual returns (uint256, uint256) {
    return _quoteHypotheticalExactOutputSingle(
      pool, recipient, zeroForOne, amountOutDesired, priceLimitX64, bidPriceX64, askPriceX64, extensionData
    );
  }

  // ============ External: hypothetical quotes (multihop) ============

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactInput(QuoteHypotheticalExactInputParams calldata params)
    external
    returns (uint256, uint256)
  {
    _validateQuotePath(params.pools, params.extensionDatas);
    _validateHypotheticalPrices(params.pools.length, params.bidPricesX64, params.askPricesX64);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountIn;

    for (uint256 i = 0; i <= last; i++) {
      bool zeroForOne = _resolveZeroForOneBitmap(params.zeroForOneBitMap, i);
      (uint256 hopAmountIn, uint256 hopAmountOut) = _quoteHypotheticalExactInputSingle(
        params.pools[i],
        address(this),
        zeroForOne,
        amount,
        _openLimit(zeroForOne),
        params.bidPricesX64[i],
        params.askPricesX64[i],
        params.extensionDatas[i]
      );
      if (hopAmountIn < amount) revert InvalidInputAmountAtHop(uint8(i), hopAmountIn, amount);
      if (i == last) return (params.amountIn, hopAmountOut);
      amount = _toUint128(hopAmountOut);
    }

    revert InvalidSwapDeltas();
  }

  /// @inheritdoc IMetricOmmSwapQuoter
  function quoteHypotheticalExactOutput(QuoteHypotheticalExactOutputParams calldata params)
    external
    returns (uint256 amountIn, uint256 amountOut)
  {
    _validateQuotePath(params.pools, params.extensionDatas);
    _validateHypotheticalPrices(params.pools.length, params.bidPricesX64, params.askPricesX64);

    uint256 last = params.pools.length - 1;
    uint128 amount = params.amountOut;
    amountOut = params.amountOut;

    for (uint256 i = last + 1; i > 0; i--) {
      uint256 hop = i - 1;
      bool zeroForOne = _resolveZeroForOneBitmap(params.zeroForOneBitMap, hop);
      (uint256 hopAmountIn, uint256 hopAmountOut) = _quoteHypotheticalExactOutputSingle(
        params.pools[hop],
        address(this),
        zeroForOne,
        amount,
        _openLimit(zeroForOne),
        params.bidPricesX64[hop],
        params.askPricesX64[hop],
        params.extensionDatas[hop]
      );
      if (hopAmountOut != amount) revert InvalidOutputAmountAtHop(uint8(hop), hopAmountOut, amount);
      if (hop == 0) {
        amountIn = hopAmountIn;
        return (amountIn, amountOut);
      }
      amount = _toUint128(hopAmountIn);
    }

    revert InvalidSwapDeltas();
  }

  // ============ External: callback ============

  /// @inheritdoc IMetricOmmSwapCallback
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    revert QuoteSwapResult(amount0Delta, amount1Delta);
  }

  // ============ Internal: single-hop orchestration ============

  function _quoteLiveExactInSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) internal returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteLiveSwap(pool, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, extensionData);
    return _toUnsignedAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  function _quoteLiveExactOutSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) internal returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) =
      _quoteLiveSwap(pool, recipient, zeroForOne, _toSignedExactOutput(amountOutDesired), priceLimitX64, extensionData);
    return _toUnsignedAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  function _quoteHypotheticalExactInputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) internal returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteHypotheticalSwap(
      pool, recipient, zeroForOne, _toSignedExactInput(amountIn), priceLimitX64, bidPriceX64, askPriceX64, extensionData
    );
    return _toUnsignedAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  function _quoteHypotheticalExactOutputSingle(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) internal returns (uint256, uint256) {
    _validatePriceLimit(zeroForOne, priceLimitX64);
    (int128 amount0Delta, int128 amount1Delta) = _quoteHypotheticalSwap(
      pool,
      recipient,
      zeroForOne,
      _toSignedExactOutput(amountOutDesired),
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      extensionData
    );
    return _toUnsignedAmounts(zeroForOne, amount0Delta, amount1Delta);
  }

  // ============ Internal: live quote orchestration ============

  function _quoteLiveSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPoolActions(pool)
      .swap(recipient, zeroForOne, amountSpecified, priceLimitX64, hex"", extensionData) returns (
      int128, int128
    ) {
      revert QuoteDidNotRevert();
    } catch (bytes memory reason) {
      return _decodeLiveQuoteResult(reason, pool);
    }
  }

  function _decodeLiveQuoteResult(bytes memory reason, address pool)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) == QuoteSwapResult.selector) {
      int256 a0;
      int256 a1;
      assembly ("memory-safe") {
        a0 := mload(add(reason, 36))
        a1 := mload(add(reason, 68))
      }
      // forge-lint: disable-next-line(unsafe-typecast)
      amount0Delta = int128(a0);
      // forge-lint: disable-next-line(unsafe-typecast)
      amount1Delta = int128(a1);
      return (amount0Delta, amount1Delta);
    }
    revert WrappedError(pool, IMetricOmmPoolActions.swap.selector, reason);
  }

  // ============ Internal: hypothetical quote orchestration ============

  function _quoteHypotheticalSwap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes memory extensionData
  ) internal returns (int128 amount0Delta, int128 amount1Delta) {
    try IMetricOmmPool(pool)
      .simulateSwapAndRevert(
        recipient, zeroForOne, amountSpecified, priceLimitX64, bidPriceX64, askPriceX64, extensionData
      ) {
      revert HypotheticalQuoteDidNotRevert();
    } catch (bytes memory reason) {
      return _decodeHypotheticalQuoteResult(reason, pool);
    }
  }

  function _decodeHypotheticalQuoteResult(bytes memory reason, address pool)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) == IMetricOmmPoolActions.SimulateSwap.selector) {
      int256 a0;
      int256 a1;
      assembly ("memory-safe") {
        a0 := mload(add(reason, 36))
        a1 := mload(add(reason, 68))
      }
      // forge-lint: disable-next-line(unsafe-typecast)
      amount0Delta = int128(a0);
      // forge-lint: disable-next-line(unsafe-typecast)
      amount1Delta = int128(a1);
      return (amount0Delta, amount1Delta);
    }
    revert WrappedError(pool, IMetricOmmPoolActions.simulateSwapAndRevert.selector, reason);
  }

  function _toUnsignedAmounts(bool zeroForOne, int128 amount0Delta, int128 amount1Delta)
    internal
    pure
    returns (uint256 amountIn, uint256 amountOut)
  {
    if (zeroForOne) {
      if (amount0Delta <= 0 || amount1Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint256(uint128(amount0Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint256(uint128(-amount1Delta));
    } else {
      if (amount1Delta <= 0 || amount0Delta >= 0) revert InvalidSwapDeltas();
      // forge-lint: disable-next-line(unsafe-typecast)
      amountIn = uint256(uint128(amount1Delta));
      // forge-lint: disable-next-line(unsafe-typecast)
      amountOut = uint256(uint128(-amount0Delta));
    }
  }

  function _validateQuotePath(address[] calldata pools, bytes[] calldata extensionDatas) internal pure {
    if (pools.length == 0 || extensionDatas.length != pools.length || pools.length > MAX_PATH_POOLS) {
      revert InvalidPath();
    }
  }

  function _validateHypotheticalPrices(
    uint256 poolCount,
    uint128[] calldata bidPricesX64,
    uint128[] calldata askPricesX64
  ) internal pure {
    if (bidPricesX64.length != poolCount || askPricesX64.length != poolCount) {
      revert InvalidPath();
    }
  }

  function _validatePriceLimit(bool zeroForOne, uint128 priceLimitX64) internal pure {
    if (zeroForOne) {
      if (priceLimitX64 == type(uint128).max) revert InvalidPriceLimitForDirection(true, priceLimitX64);
      return;
    }
    if (priceLimitX64 == 0) revert InvalidPriceLimitForDirection(false, priceLimitX64);
  }

  function _openLimit(bool zeroForOne) internal pure returns (uint128) {
    return zeroForOne ? 0 : type(uint128).max;
  }

  function _resolveZeroForOneBitmap(uint256 bitMap, uint256 hop) internal pure returns (bool zeroForOne) {
    return (bitMap >> hop) & 1 == 1;
  }

  function _toSignedExactInput(uint128 amountIn) internal pure returns (int128 amountSpecified) {
    if (amountIn > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountIn);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = int128(amountIn);
  }

  function _toSignedExactOutput(uint128 amountOutDesired) internal pure returns (int128 amountSpecified) {
    if (amountOutDesired > MAX_INT128_AS_UINT128) revert AmountTooLarge(amountOutDesired);
    // forge-lint: disable-next-line(unsafe-typecast)
    amountSpecified = -int128(amountOutDesired);
  }

  function _toUint128(uint256 amount) internal pure returns (uint128) {
    if (amount > MAX_INT128_AS_UINT128) revert AmountTooLarge(uint128(amount));
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint128(amount);
  }
}
