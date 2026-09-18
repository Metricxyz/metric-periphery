// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExternalSwap} from "../interfaces/IExternalSwap.sol";
import {ExternalSwapExecutor} from "./ExternalSwapExecutor.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";

/// @title ExternalSwap
/// @notice External swaps with verified router refunds and recipient output.
abstract contract ExternalSwap is IExternalSwap, PeripheryPayments {
  /// @inheritdoc IExternalSwap
  function externalSwap(address executor, ExternalSwapParams calldata params)
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
    if (params.recipient == executor) {
      revert InvalidExternalSwapRecipient(params.recipient);
    }

    pay(params.tokenIn, msg.sender, executor, params.amountInMaximum);
    uint256 refundBalanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
    uint256 recipientBalanceBefore = IERC20(params.tokenOut).balanceOf(params.recipient);

    amountSpent = ExternalSwapExecutor(executor).swap(params);
    amountOut = IERC20(params.tokenOut).balanceOf(params.recipient) - recipientBalanceBefore;

    if (amountSpent > params.amountInMaximum) revert ExternalSwapExcessiveInput(amountSpent, params.amountInMaximum);
    if (amountOut < params.amountOutMinimum) revert ExternalSwapInsufficientOutput(amountOut, params.amountOutMinimum);
    _checkMinimumBalanceIncrease(
      params.tokenIn, address(this), refundBalanceBefore, params.amountInMaximum - amountSpent
    );
  }

  function _checkMinimumBalanceIncrease(address token, address account, uint256 balanceBefore, uint256 increase)
    private
    view
  {
    uint256 expectedBalance = balanceBefore + increase;
    uint256 actualBalance = IERC20(token).balanceOf(account);
    if (actualBalance < expectedBalance) {
      revert ExternalSwapBalanceMismatch(token, account, expectedBalance, actualBalance);
    }
  }
}
