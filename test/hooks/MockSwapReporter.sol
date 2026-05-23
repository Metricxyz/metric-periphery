// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IPriceProviderSwapReporter} from "@metric-core/interfaces/IPriceProvider/IPriceProviderSwapReporter.sol";

contract MockSwapReporter is IPriceProviderSwapReporter {
  bool public shouldRevert;
  uint256 public reportCount;

  address public lastSender;
  address public lastRecipient;
  bool public lastZeroForOne;
  int128 public lastAmountSpecified;
  uint128 public lastPriceLimitX64;
  int256 public lastAmount0Delta;
  int256 public lastAmount1Delta;
  int8 public lastCurBinIdx;
  uint104 public lastCurPosInBin;

  function setShouldRevert(bool value) external {
    shouldRevert = value;
  }

  function reportSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    int256 amount0Delta,
    int256 amount1Delta,
    int8 curBinIdx,
    uint104 curPosInBin
  ) external {
    if (shouldRevert) revert("MockSwapReporter: revert");
    reportCount++;
    lastSender = sender;
    lastRecipient = recipient;
    lastZeroForOne = zeroForOne;
    lastAmountSpecified = amountSpecified;
    lastPriceLimitX64 = priceLimitX64;
    lastAmount0Delta = amount0Delta;
    lastAmount1Delta = amount1Delta;
    lastCurBinIdx = curBinIdx;
    lastCurPosInBin = curPosInBin;
  }
}
