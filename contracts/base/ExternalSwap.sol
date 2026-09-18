// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExternalSwap} from "../interfaces/IExternalSwap.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {ExternalSwapExecutor} from "./ExternalSwapExecutor.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";

/// @title ExternalSwap
/// @notice External swaps with verified router refunds and recipient output.
abstract contract ExternalSwap is IExternalSwap, PeripheryPayments {
  /// @inheritdoc IExternalSwap
  function externalSwap(address executor, bool payerIsRouter, bool refundAsNative, ExternalSwapParams calldata params)
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
    if (refundAsNative && params.tokenIn != WETH) revert InvalidNativeRefundToken(params.tokenIn);

    address payer = payerIsRouter ? address(this) : msg.sender;

    pay(params.tokenIn, payer, executor, params.amountInMaximum);
    uint256 refundBalanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
    uint256 recipientBalanceBefore = IERC20(params.tokenOut).balanceOf(params.recipient);

    ExternalSwapExecutor(executor).swap(params);
    uint256 unspend = _balanceIncrease(params.tokenIn, address(this), refundBalanceBefore);
    amountSpent = Math.saturatingSub(params.amountInMaximum, unspend);
    amountOut = _balanceIncrease(params.tokenOut, params.recipient, recipientBalanceBefore);

    if (amountOut < params.amountOutMinimum) revert ExternalSwapInsufficientOutput(amountOut, params.amountOutMinimum);
    if (payerIsRouter) return (amountOut, amountSpent);
    _refundInput(params.tokenIn, unspend, refundAsNative);
  }

  function _refundInput(address token, uint256 amount, bool refundAsNative) private {
    if (amount == 0) return;
    if (refundAsNative) {
      IWETH9(WETH).withdraw(amount);
      _transferETH(msg.sender, amount);
    } else {
      SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
    }
  }

  function _balanceIncrease(address token, address account, uint256 balanceBefore) private view returns (uint256) {
    uint256 actualBalance = IERC20(token).balanceOf(account);
    if (actualBalance < balanceBefore) {
      revert ExternalSwapBalanceMismatch(token, account, balanceBefore, actualBalance);
    }
    return actualBalance - balanceBefore;
  }
}
