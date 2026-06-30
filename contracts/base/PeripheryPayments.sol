// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";

/// @title PeripheryPayments
/// @notice Shared payment, unwrap, sweep, and refund helpers for MetricOmm routers.
abstract contract PeripheryPayments is IPeripheryPayments {
  using SafeERC20 for IERC20;

  /// @notice Constructor received zero WETH address.
  error InvalidWETH();
  /// @notice ETH was sent from an address other than WETH.
  error NotWETH();
  /// @notice Contract WETH balance is below the requested minimum.
  error InsufficientWETH(uint256 required, uint256 available);
  /// @notice Contract token balance is below the requested minimum.
  error InsufficientToken(address token, uint256 required, uint256 available);
  /// @notice Native ETH transfer failed.
  error ETHTransferFailed();

  address internal immutable WETH;

  constructor(address weth) {
    if (weth == address(0)) revert InvalidWETH();
    WETH = weth;
  }

  receive() external payable {
    if (msg.sender != WETH) revert NotWETH();
  }

  /// @inheritdoc IPeripheryPayments
  function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override {
    uint256 balanceWETH = IERC20(WETH).balanceOf(address(this));
    if (balanceWETH < amountMinimum) revert InsufficientWETH(amountMinimum, balanceWETH);

    if (balanceWETH > 0) {
      IWETH9(WETH).withdraw(balanceWETH);
      _transferETH(recipient, balanceWETH);
    }
  }

  /// @inheritdoc IPeripheryPayments
  function sweepToken(address token, uint256 amountMinimum, address recipient) public payable override {
    uint256 balanceToken = IERC20(token).balanceOf(address(this));
    if (balanceToken < amountMinimum) revert InsufficientToken(token, amountMinimum, balanceToken);

    if (balanceToken > 0) {
      IERC20(token).safeTransfer(recipient, balanceToken);
    }
  }

  /// @inheritdoc IPeripheryPayments
  function refundETH() external payable override {
    uint256 balance = address(this).balance;
    if (balance > 0) {
      _transferETH(msg.sender, balance);
    }
  }

  /// @param token The token to pay.
  /// @param payer The entity that must pay.
  /// @param recipient The entity that will receive payment.
  /// @param value The amount to pay.
  function pay(address token, address payer, address recipient, uint256 value) internal {
    // If the payer is contract it means we are in the middle of a path. In the middle of a path we operate on ERC20 only.
    if (payer == address(this)) {
      IERC20(token).safeTransfer(recipient, value);
    } else if (token == WETH) {
      uint256 nativeBalance = address(this).balance;
      if (nativeBalance >= value) {
        IWETH9(WETH).deposit{value: value}();
        IERC20(WETH).safeTransfer(recipient, value);
      } else if (nativeBalance > 0) {
        IWETH9(WETH).deposit{value: nativeBalance}();
        IERC20(WETH).safeTransfer(recipient, nativeBalance);
        IERC20(WETH).safeTransferFrom(payer, recipient, value - nativeBalance);
      } else {
        IERC20(WETH).safeTransferFrom(payer, recipient, value);
      }
    } else {
      IERC20(token).safeTransferFrom(payer, recipient, value);
    }
  }

  function _transferETH(address to, uint256 value) internal {
    (bool ok,) = to.call{value: value}("");
    if (!ok) revert ETHTransferFailed();
  }
}
