// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title MetricOmmSwapQuoteDecode
/// @notice Decode swap deltas from deliberate revert payloads.
library MetricOmmSwapQuoteDecode {
  function decodeSwapDeltas(bytes memory reason, bytes4 expectedSelector)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta, bool matched)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) != expectedSelector) return (0, 0, false);

    int256 a0;
    int256 a1;
    assembly ("memory-safe") {
      a0 := mload(add(reason, 36))
      a1 := mload(add(reason, 68))
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    amount0Delta = int128(a0);
    // forge-lint: disable-next-line(unsafe-typecast)
    amount1Delta = int128(a1);
    return (amount0Delta, amount1Delta, true);
  }
}
