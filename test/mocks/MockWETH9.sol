// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";

/// @title MockWETH9
/// @notice Minimal WETH9-like ERC20 for tests.
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
