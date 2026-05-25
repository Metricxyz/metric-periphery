// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {SwapAllowlistSubhookHarness} from "./SubhookHarness.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
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
    harness.setAllowedToSwap(pool, swapper, true);
    harness.exposeBeforeSwapAllowlist(swapper);
  }

  function test_onlyPoolAdminCanSetSwappers() public {
    vm.prank(admin);
    harness.setAllowedToSwap(pool, swapper, true);
    assertTrue(harness.isAllowedToSwap(pool, swapper));

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, pool, swapper, admin));
    harness.setAllowedToSwap(pool, swapper, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(harness.isAllowedToSwap(pool, swapper));
  }
}
