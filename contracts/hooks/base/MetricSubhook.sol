// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title MetricSubhook
/// @notice Base for hook mixins; each subhook declares the pool callbacks it uses.
abstract contract MetricSubhook {
  /// @notice Permission flags required by this subhook (`MetricHooks.*_FLAG`).
  function subhookPermissions() internal pure virtual returns (uint16);
}
