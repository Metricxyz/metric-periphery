// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {SwapAllowlistSubhookHarness} from "./SubhookHarness.sol";
import {MetricFactorySubhook} from "../../contracts/hooks/base/MetricFactorySubhook.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

contract SwapAllowlistSubhookTest is Test {
  AllowlistFactoryStub factoryStub;
  SwapAllowlistSubhookHarness harness;

  address admin = makeAddr("admin");
  address swapper = makeAddr("swapper");
  address pool = makeAddr("pool");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    factoryStub.setPoolAdmin(pool, admin);
    harness = new SwapAllowlistSubhookHarness(pool, address(factoryStub));
  }

  function test_revertsWhenSwapperNotAllowed() public {
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    harness.exposeBeforeSwapAllowlist(swapper);
  }

  function test_passesWhenSwapperAllowed() public {
    vm.prank(admin);
    harness.setAllowedToSwap(swapper, true);
    harness.exposeBeforeSwapAllowlist(swapper);
  }

  function test_onlyPoolAdminCanSetSwappers() public {
    vm.prank(admin);
    harness.setAllowedToSwap(swapper, true);
    assertTrue(harness.isAllowedToSwap(swapper));

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(MetricFactorySubhook.OnlyPoolAdmin.selector, pool, swapper, admin));
    harness.setAllowedToSwap(swapper, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(harness.isAllowedToSwap(swapper));
  }
}
