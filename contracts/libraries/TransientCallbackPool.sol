// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSimpleRouter} from "../interfaces/IMetricOmmSimpleRouter.sol";

/// @title TransientCallbackPool
/// @notice EIP-1153 transient slot for swap callback context.
/// @dev Layout: bits 0-159 pool, bits 160-167 callback mode, bits 168+ tradesLeft (exact-output recursion only).
library TransientCallbackPool {
  uint256 private constant T_SLOT = 0;
  uint256 private constant T_AMOUNT_IN_SLOT = 1;
  uint256 private constant T_PAYER_SLOT = 2;
  uint256 private constant T_TOKEN_TO_PAY_SLOT = 3;
  uint256 private constant CALLBACK_MODE_OFFSET = 160;
  uint256 private constant TRADES_LEFT_OFFSET = 168;
  uint256 private constant CALLBACK_MODE_MASK = 0xff;

  function update(address pool, uint256 tradesLeft) internal {
    uint256 callbackMode = getCallbackMode();
    uint256 value = uint256(uint160(pool));
    value |= (uint256(callbackMode) << CALLBACK_MODE_OFFSET);
    value |= tradesLeft << TRADES_LEFT_OFFSET;
    _tstore(T_SLOT, value);
  }

  function set(address pool, uint8 callbackMode, uint256 tradesLeft, address payer, address tokenToPay) internal {
    uint256 value = uint256(uint160(pool));
    value |= (uint256(callbackMode) << CALLBACK_MODE_OFFSET);
    value |= tradesLeft << TRADES_LEFT_OFFSET;
    _tstore(T_SLOT, value);
    _tstoreAddress(T_PAYER_SLOT, payer);
    _tstoreAddress(T_TOKEN_TO_PAY_SLOT, tokenToPay);
  }

  function set(address pool, uint8 callbackMode, address payer, address tokenToPay) internal {
    uint256 value = uint256(uint160(pool));
    value |= (uint256(callbackMode) << CALLBACK_MODE_OFFSET);
    _tstore(T_SLOT, value);
    _tstoreAddress(T_PAYER_SLOT, payer);
    _tstoreAddress(T_TOKEN_TO_PAY_SLOT, tokenToPay);
  }

  function getPool() internal view returns (address pool) {
    // forge-lint: disable-next-line(unsafe-typecast)
    pool = address(uint160(_tload(T_SLOT)));
  }

  function getCallbackMode() internal view returns (uint8 callbackMode) {
    // forge-lint: disable-next-line(unsafe-typecast)
    callbackMode = uint8((_tload(T_SLOT) >> CALLBACK_MODE_OFFSET) & CALLBACK_MODE_MASK);
  }

  function getTradesLeft() internal view returns (uint8 tradesLeft) {
    // forge-lint: disable-next-line(unsafe-typecast)
    tradesLeft = uint8(_tload(T_SLOT) >> TRADES_LEFT_OFFSET);
  }

  function setAmountIn(uint256 amountIn) internal {
    _tstore(T_AMOUNT_IN_SLOT, amountIn);
  }

  function getAmountIn() internal view returns (uint256 amountIn) {
    amountIn = _tload(T_AMOUNT_IN_SLOT);
  }

  function getPayer() internal view returns (address payer) {
    payer = _tloadAddress(T_PAYER_SLOT);
  }

  function getTokenToPay() internal view returns (address tokenToPay) {
    tokenToPay = _tloadAddress(T_TOKEN_TO_PAY_SLOT);
  }

  function clear() internal {
    _tstore(T_SLOT, 0);
    _tstore(T_AMOUNT_IN_SLOT, 0);
    _tstoreAddress(T_PAYER_SLOT, address(0));
    _tstoreAddress(T_TOKEN_TO_PAY_SLOT, address(0));
  }

  function requireCaller(address caller) internal view {
    if (caller != getPool()) revert IMetricOmmSimpleRouter.InvalidCallbackCaller();
  }

  function _tload(uint256 slot) private view returns (uint256 value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  function _tstore(uint256 slot, uint256 value) private {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  function _tloadAddress(uint256 slot) private view returns (address value) {
    // forge-lint: disable-next-line(unsafe-typecast)
    value = address(uint160(_tload(slot)));
  }

  function _tstoreAddress(uint256 slot, address value) private {
    _tstore(slot, uint256(uint160(value)));
  }
}
