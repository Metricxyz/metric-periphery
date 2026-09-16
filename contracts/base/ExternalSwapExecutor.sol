// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BoundedReturnData} from "../libraries/BoundedReturnData.sol";
import {IExternalSwap} from "../interfaces/IExternalSwap.sol";

/// @dev Only the bound router may execute swaps. Users approve the router, never this contract.
/// @dev Existing input/output balances are donated to the next swap using those tokens.
contract ExternalSwapExecutor {
  using SafeERC20 for IERC20;

  error UnauthorizedCaller();
  error InvalidRouter();

  address public immutable router;

  constructor(address router_) {
    if (router_ == address(0)) revert InvalidRouter();
    router = router_;
  }

  function swap(IExternalSwap.ExternalSwapParams calldata params, address payer)
    external
    returns (uint256 amountOut, uint256 amountSpent)
  {
    if (msg.sender != router) revert UnauthorizedCaller();
    IERC20 tokenIn = IERC20(params.tokenIn);
    IERC20 tokenOut = IERC20(params.tokenOut);
    uint256 inputBefore = tokenIn.balanceOf(address(this));
    uint256 outputBefore = tokenOut.balanceOf(address(this));

    tokenIn.forceApprove(params.externalRouter, params.amountInMaximum);
    _callExternalRouter(params.externalRouter, params.externalRouterCalldata);
    tokenIn.forceApprove(params.externalRouter, 0);

    uint256 inputAfter = tokenIn.balanceOf(address(this));
    uint256 outputAfter = tokenOut.balanceOf(address(this));
    amountSpent = Math.saturatingSub(inputBefore, inputAfter);
    amountOut = outputAfter - outputBefore;
    if (inputAfter > 0) tokenIn.safeTransfer(payer, inputAfter);
    if (outputAfter > 0) tokenOut.safeTransfer(params.recipient, outputAfter);
  }

  function _callExternalRouter(address target, bytes calldata data) private {
    if (LowLevelCall.callNoReturn(target, data)) return;
    bytes memory reason = BoundedReturnData.read();
    if (reason.length == 0) revert IExternalSwap.ExternalSwapFailed();
    LowLevelCall.bubbleRevert(reason);
  }
}
