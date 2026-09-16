// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExternalSwap} from "../interfaces/IExternalSwap.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";

/// @title ExternalSwap
/// @notice Standalone swap through an arbitrary external router, accounted for by measured balance deltas rather
///         than trust in the router's return data.
abstract contract ExternalSwap is IExternalSwap, PeripheryPayments {
  using SafeERC20 for IERC20;

  /// @inheritdoc IExternalSwap
  /// @dev Unlike a MetricOmm leg, an external router pulls from its own `msg.sender`, so this router must take
  ///      custody first. Nothing about `externalRouterCalldata` is trusted: the approval is capped at
  ///      `amountInMaximum`, the output is the measured balance delta rather than anything the call returns, and
  ///      whatever input the call did not spend goes back to the caller.
  function externalSwap(ExternalSwapParams calldata params)
    external
    payable
    override
    nonReentrant
    returns (uint256 amountOut, uint256 amountSpent)
  {
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > params.deadline) revert DeadlineExpired(params.deadline, block.timestamp);
    if (params.externalRouter == address(this) || params.externalRouter.code.length == 0) {
      revert InvalidExternalRouter(params.externalRouter);
    }
    if (params.externalRouterCalldata.length == 0) revert EmptyExternalRouterCalldata();
    if (params.tokenIn == params.tokenOut) revert SameTokenExternalSwap();

    IERC20 tokenIn = IERC20(params.tokenIn);
    IERC20 tokenOut = IERC20(params.tokenOut);
    uint256 tokenInBefore = tokenIn.balanceOf(address(this));
    uint256 tokenOutBefore = tokenOut.balanceOf(address(this));

    pay(params.tokenIn, msg.sender, address(this), params.amountInMaximum);
    tokenIn.forceApprove(params.externalRouter, params.amountInMaximum);

    _callExternalRouter(params.externalRouter, params.externalRouterCalldata);

    tokenIn.forceApprove(params.externalRouter, 0);

    amountOut = tokenOut.balanceOf(address(this)) - tokenOutBefore;
    if (amountOut < params.amountOutMinimum) revert ExternalSwapInsufficientOutput(amountOut, params.amountOutMinimum);
    tokenOut.safeTransfer(params.recipient, amountOut);

    uint256 unspent = tokenIn.balanceOf(address(this)) - tokenInBefore;
    if (unspent > 0) tokenIn.safeTransfer(msg.sender, unspent);
    amountSpent = params.amountInMaximum - unspent;
  }

  /// @dev Successful return data is unused. Only a bounded failure diagnostic is copied so the external target
  ///      cannot force an unbounded allocation in this call frame.
  function _callExternalRouter(address target, bytes calldata data) private {
    bool success;
    bytes memory reason;
    assembly ("memory-safe") {
      success := call(gas(), target, 0, data.offset, data.length, 0, 0)
      if iszero(success) {
        let size := returndatasize()
        if gt(size, 4096) { size := 4096 }
        reason := mload(0x40)
        mstore(reason, size)
        returndatacopy(add(reason, 0x20), 0, size)
        mstore(0x40, and(add(add(reason, size), 0x3f), not(0x1f)))
      }
    }
    if (!success) _bubbleExternalRouterRevert(reason);
  }

  /// @dev Re-reverts a captured revert reason; reverts with a local error when the target returned none.
  function _bubbleExternalRouterRevert(bytes memory reason) private pure {
    if (reason.length == 0) revert ExternalSwapFailed();
    assembly ("memory-safe") {
      revert(add(reason, 0x20), mload(reason))
    }
  }
}
