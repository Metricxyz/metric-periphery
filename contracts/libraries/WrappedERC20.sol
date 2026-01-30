// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

/// @title WrappedERC20
/// @notice ERC20 helpers that wrap failures in IMetricOmmPoolActions.WrappedError for better diagnostics
library WrappedERC20 {
  function safeTransfer(address token, address to, uint256 value) internal {
    bytes memory ret =
      _call(token, abi.encodeWithSelector(IERC20.transfer.selector, to, value), IERC20.transfer.selector, "transfer");
    if (ret.length > 0 && !abi.decode(ret, (bool))) {
      revert IMetricOmmPoolActions.WrappedError(token, IERC20.transfer.selector, ret, bytes("ERC20_ST"));
    }
  }

  function safeTransferFrom(address token, address from, address to, uint256 value) internal {
    bytes memory ret = _call(
      token,
      abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value),
      IERC20.transferFrom.selector,
      "transferFrom"
    );
    if (ret.length > 0 && !abi.decode(ret, (bool))) {
      revert IMetricOmmPoolActions.WrappedError(token, IERC20.transferFrom.selector, ret, bytes("ERC20_STF"));
    }
  }

  function safeBalanceOf(address token, address owner) internal view returns (uint256) {
    (bool success, bytes memory ret) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, owner));
    if (!success) {
      revert IMetricOmmPoolActions.WrappedError(token, IERC20.balanceOf.selector, ret, bytes("ERC20_SB"));
    }
    if (ret.length < 32) {
      revert IMetricOmmPoolActions.WrappedError(token, IERC20.balanceOf.selector, ret, bytes("ERC20_SB_T"));
    }
    return abi.decode(ret, (uint256));
  }

  function _call(address token, bytes memory callData, bytes4 selector, string memory details)
    private
    returns (bytes memory)
  {
    (bool success, bytes memory ret) = token.call(callData);
    if (!success) {
      revert IMetricOmmPoolActions.WrappedError(token, selector, ret, bytes(details));
    }
    return ret;
  }
}
