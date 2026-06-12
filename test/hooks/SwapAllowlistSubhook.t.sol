// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {SwapAllowlistHook} from "../../contracts/hooks/SwapAllowlistHook.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MockHookPool} from "./MockHookPool.sol";

contract SwapAllowlistHookTest is Test {
  AllowlistFactoryStub factoryStub;
  SwapAllowlistHook hook;
  MockHookPool pool;

  address admin = makeAddr("admin");
  address swapper = makeAddr("swapper");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    pool = new MockHookPool(address(factoryStub));
    factoryStub.setPoolAdmin(address(pool), admin);
    hook = new SwapAllowlistHook(address(factoryStub));
  }

  function test_revertsWhenSwapperNotAllowed() public {
    vm.prank(address(pool));
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    hook.beforeSwap(swapper, address(0), false, 0, 0, 0, 0, 0, "");
  }

  function test_passesWhenSwapperAllowed() public {
    vm.prank(admin);
    hook.setAllowedToSwap(address(pool), swapper, true);

    vm.prank(address(pool));
    hook.beforeSwap(swapper, address(0), false, 0, 0, 0, 0, 0, "");
  }

  function test_onlyPoolAdminCanSetSwappers() public {
    vm.prank(admin);
    hook.setAllowedToSwap(address(pool), swapper, true);
    assertTrue(hook.isAllowedToSwap(address(pool), swapper));

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, address(pool), swapper, admin));
    hook.setAllowedToSwap(address(pool), swapper, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(hook.isAllowedToSwap(address(pool), swapper));
  }
}
