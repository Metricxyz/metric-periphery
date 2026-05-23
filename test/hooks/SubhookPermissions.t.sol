// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricHooks} from "@metric-core/libraries/MetricHooks.sol";
import {StandardMetricHook} from "../../contracts/hooks/examples/StandardMetricHook.sol";

contract SubhookPermissionsTest is Test {
  function test_standardMetricHook_orCombinesSubhookPermissions() public {
    StandardMetricHook hook = new StandardMetricHook(makeAddr("pool"), makeAddr("factory"));

    uint16 expected = MetricHooks.BEFORE_SWAP_FLAG | MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG | MetricHooks.AFTER_SWAP_FLAG;
    assertEq(hook.getHookPermissions(), expected);
  }
}
