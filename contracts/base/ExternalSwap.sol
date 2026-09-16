// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExternalSwap} from "../interfaces/IExternalSwap.sol";
import {ExternalSwapExecutor} from "./ExternalSwapExecutor.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";

/// @title ExternalSwap
/// @notice External swaps with verified payer and recipient settlement.
abstract contract ExternalSwap is IExternalSwap, PeripheryPayments {
  /// @dev Isolates external calls from users' token allowances granted to this router.
  ExternalSwapExecutor public immutable isolatedExternalExecutor;

  constructor(address executor) {
    if (executor.code.length == 0 || ExternalSwapExecutor(executor).router() != address(this)) {
      revert InvalidExternalExecutor(executor);
    }
    isolatedExternalExecutor = ExternalSwapExecutor(executor);
  }

  /// @inheritdoc IExternalSwap
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

    pay(params.tokenIn, msg.sender, address(isolatedExternalExecutor), params.amountInMaximum);
    uint256 payerBalanceBefore = IERC20(params.tokenIn).balanceOf(msg.sender);
    uint256 recipientBalanceBefore = IERC20(params.tokenOut).balanceOf(params.recipient);

    (amountOut, amountSpent) = isolatedExternalExecutor.swap(params, msg.sender);
    if (amountSpent > params.amountInMaximum) revert ExternalSwapExcessiveInput(amountSpent, params.amountInMaximum);
    if (amountOut < params.amountOutMinimum) revert ExternalSwapInsufficientOutput(amountOut, params.amountOutMinimum);
    _checkMinimumBalanceIncrease(params.tokenIn, msg.sender, payerBalanceBefore, params.amountInMaximum - amountSpent);
    _checkMinimumBalanceIncrease(params.tokenOut, params.recipient, recipientBalanceBefore, amountOut);
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
