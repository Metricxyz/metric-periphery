// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {AllowanceHolderBase} from "../vendor/zero-ex/src/allowanceholder/AllowanceHolderBase.sol";
import {TransientStorage} from "../vendor/zero-ex/src/allowanceholder/TransientStorage.sol";

/// @dev Test harness for 0x commit e80cfb0234cc7153abb34e63ad80e9ea2cf27dff.
/// Same exec implementation as AllowanceHolder.sol; compiler pragma relaxed and
/// canonical-address constructor check omitted for local tests only.
contract PinnedAllowanceHolder is TransientStorage, AllowanceHolderBase {
  function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
    internal
    override
    returns (bytes memory)
  {
    (bytes memory result, address sender, TSlot allowance) = _exec(operator, token, amount, target, data);
    if (sender != tx.origin) _set(allowance, 0);
    return result;
  }
}
