// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAggregationRouter
/// @notice Stand-in for an external aggregator such as KyberSwap MetaAggregationRouterV2.
/// @dev Mirrors the funding model that matters to the periphery router: the aggregator pulls the input from its
///      own `msg.sender` rather than through a swap callback, and pays the output to an encoded receiver. Input
///      pulled and output paid are supplied separately so a test can make the leg spend less than it was approved.
contract MockAggregationRouter {
  /// @notice Forced failure used to exercise the both-legs-failed path.
  error MockAggregatorReverted();

  bool public shouldRevert;
  bool public customResponse;
  bool public revertResponse;
  uint256 public responseSize;

  function setResponse(uint256 size, bool shouldRevertResponse) external {
    customResponse = true;
    responseSize = size;
    revertResponse = shouldRevertResponse;
  }

  function setShouldRevert(bool value) external {
    shouldRevert = value;
  }

  function swap(address tokenIn, address tokenOut, uint256 amountInToPull, uint256 amountOut, address dstReceiver)
    external
  {
    if (shouldRevert) revert MockAggregatorReverted();
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountInToPull);
    IERC20(tokenOut).transfer(dstReceiver, amountOut);
    if (customResponse) {
      uint256 size = responseSize;
      bool fail = revertResponse;
      assembly ("memory-safe") {
        let ptr := mload(0x40)
        // Deterministic bytes, including for a short or empty response.
        calldatacopy(ptr, calldatasize(), size)
        mstore(ptr, 0xdeadbeef)
        if fail { revert(ptr, size) }
        return(ptr, size)
      }
    }
  }
}
