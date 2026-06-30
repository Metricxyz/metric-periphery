// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20PermitAllowed} from "../interfaces/external/IERC20PermitAllowed.sol";
import {ISelfPermit} from "../interfaces/ISelfPermit.sol";

/// @title SelfPermit
/// @notice Functionality to call permit on any EIP-2612-compliant token for use in the route.
/// @dev This follows the Uniswap v3-periphery pattern using OpenZeppelin's IERC20Permit.
///      Intended to be composed with Multicall.
abstract contract SelfPermit is ISelfPermit {
  /// @inheritdoc ISelfPermit
  function selfPermit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public payable {
    IERC20Permit(token).permit(msg.sender, address(this), value, deadline, v, r, s);
  }

  /// @inheritdoc ISelfPermit
  function selfPermitIfNecessary(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    external
    payable
  {
    if (IERC20(token).allowance(msg.sender, address(this)) < value) {
      selfPermit(token, value, deadline, v, r, s);
    }
  }

  /// @inheritdoc ISelfPermit
  function selfPermitAllowed(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    public
    payable
  {
    IERC20PermitAllowed(token).permit(msg.sender, address(this), nonce, expiry, true, v, r, s);
  }

  /// @inheritdoc ISelfPermit
  function selfPermitAllowedIfNecessary(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    external
    payable
  {
    if (IERC20(token).allowance(msg.sender, address(this)) < type(uint256).max) {
      selfPermitAllowed(token, nonce, expiry, v, r, s);
    }
  }
}
