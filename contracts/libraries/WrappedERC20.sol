// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrappedERC20
/// @notice ERC20 helpers that wrap low-level failures for clearer diagnostics.
library WrappedERC20 {
  error WrappedError(address token, bytes4 selector, bytes reason, bytes additionalInfo);

  function safeTransfer(address token, address to, uint256 value) internal {
    bytes memory ret =
      _call(token, abi.encodeWithSelector(IERC20.transfer.selector, to, value), IERC20.transfer.selector, "transfer");
    if (ret.length > 0 && !abi.decode(ret, (bool))) {
      revert WrappedError(token, IERC20.transfer.selector, ret, bytes("ERC20_ST"));
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
      revert WrappedError(token, IERC20.transferFrom.selector, ret, bytes("ERC20_STF"));
    }
  }

  function safeBalanceOf(address token, address owner) internal view returns (uint256) {
    (bool success, bytes memory ret) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, owner));
    if (!success) {
      revert WrappedError(token, IERC20.balanceOf.selector, ret, bytes("ERC20_SB"));
    }
    if (ret.length < 32) {
      revert WrappedError(token, IERC20.balanceOf.selector, ret, bytes("ERC20_SB_T"));
    }
    return abi.decode(ret, (uint256));
  }

  function _call(address token, bytes memory callData, bytes4 selector, string memory details)
    private
    returns (bytes memory)
  {
    (bool success, bytes memory ret) = token.call(callData);
    if (!success) {
      revert WrappedError(token, selector, ret, bytes(details));
    }
    return ret;
  }
}
