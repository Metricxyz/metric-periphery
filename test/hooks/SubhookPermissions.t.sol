// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {FullMetricHook} from "../../contracts/hooks/examples/FullMetricHook.sol";

contract SubhookPermissionsTest is Test {
  function test_fullMetricHook_orCombinesSubhookPermissions() public {
    FullMetricHook hook = new FullMetricHook(makeAddr("factory"));

    uint16 expected = MetricHooks.BEFORE_SWAP_FLAG | MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG | MetricHooks.AFTER_SWAP_FLAG;
    assertEq(hook.getHookPermissions(), expected);
  }
}
