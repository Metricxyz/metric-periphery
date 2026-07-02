// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {BaseMetricExtension} from "../../contracts/extensions/base/BaseMetricExtension.sol";
import {SwapAllowlistExtension} from "../../contracts/extensions/SwapAllowlistExtension.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MockExtensionPool} from "./MockExtensionPool.sol";

contract SwapAllowlistExtensionTest is Test {
  AllowlistFactoryStub factoryStub;
  SwapAllowlistExtension extension;
  MockExtensionPool pool;

  address admin = makeAddr("admin");
  address swapper = makeAddr("swapper");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    pool = new MockExtensionPool(address(factoryStub));
    factoryStub.setPoolAdmin(address(pool), admin);
    extension = new SwapAllowlistExtension(address(factoryStub));
  }

  function test_revertsWhenSwapperNotAllowed() public {
    vm.prank(address(pool));
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    extension.beforeSwap(swapper, address(0), false, 0, 0, 0, 0, 0, "");
  }

  function test_passesWhenSwapperAllowed() public {
    vm.prank(admin);
    extension.setAllowedToSwap(address(pool), swapper, true);

    vm.prank(address(pool));
    extension.beforeSwap(swapper, address(0), false, 0, 0, 0, 0, 0, "");
  }

  function test_onlyPoolAdminCanSetSwappers() public {
    vm.prank(admin);
    extension.setAllowedToSwap(address(pool), swapper, true);
    assertTrue(extension.isAllowedToSwap(address(pool), swapper));

    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(pool), swapper, admin));
    extension.setAllowedToSwap(address(pool), swapper, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(extension.isAllowedToSwap(address(pool), swapper));
  }

  function test_passesWhenAllowAllSwappers() public {
    vm.prank(admin);
    extension.setAllowAllSwappers(address(pool), true);
    assertTrue(extension.isAllowedToSwap(address(pool), swapper));

    vm.prank(address(pool));
    extension.beforeSwap(swapper, address(0), false, 0, 0, 0, 0, 0, "");
  }

  function test_onlyPoolAdminCanSetAllowAllSwappers() public {
    vm.prank(swapper);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(pool), swapper, admin));
    extension.setAllowAllSwappers(address(pool), true);
  }
}
