// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";

library BoundedReturnData {
  /// @dev Read immediately after the call; copies at most 4096 bytes.
  function read() internal pure returns (bytes memory result) {
    uint256 size = LowLevelCall.returnDataSize();
    if (size > 4096) size = 4096;
    result = new bytes(size);
    assembly ("memory-safe") {
      returndatacopy(add(result, 0x20), 0, size)
    }
  }
}
