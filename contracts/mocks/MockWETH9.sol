// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

/// @notice Minimal WETH9-like contract for tests.
contract MockWETH9 is IWETH9, ERC20 {
  error EthTransferFailed();

  constructor() ERC20("Wrapped Ether", "WETH") {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    (bool ok,) = msg.sender.call{value: amount}("");
    if (!ok) revert EthTransferFailed();
  }

  receive() external payable {
    _mint(msg.sender, msg.value);
  }
}
