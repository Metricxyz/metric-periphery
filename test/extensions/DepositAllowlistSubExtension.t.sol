// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {BaseMetricExtension} from "../../contracts/extensions/base/BaseMetricExtension.sol";
import {DepositAllowlistExtension} from "../../contracts/extensions/DepositAllowlistExtension.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {MockExtensionPool} from "./MockExtensionPool.sol";

contract DepositAllowlistExtensionTest is Test {
  AllowlistFactoryStub factoryStub;
  DepositAllowlistExtension extension;
  MockExtensionPool pool;

  address admin = makeAddr("admin");
  address depositor = makeAddr("depositor");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    pool = new MockExtensionPool(address(factoryStub));
    factoryStub.setPoolAdmin(address(pool), admin);
    extension = new DepositAllowlistExtension(address(factoryStub));
  }

  function test_revertsWhenDepositorNotAllowed() public {
    vm.prank(address(pool));
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    LiquidityDelta memory emptyDelta = LiquidityDelta({binIdxs: new int256[](0), shares: new uint256[](0)});
    extension.beforeAddLiquidity(address(0), depositor, 0, emptyDelta, "");
  }

  function test_passesWhenDepositorAllowed() public {
    vm.prank(admin);
    extension.setAllowedToDeposit(address(pool), depositor, true);

    vm.prank(address(pool));
    LiquidityDelta memory emptyDelta = LiquidityDelta({binIdxs: new int256[](0), shares: new uint256[](0)});
    extension.beforeAddLiquidity(address(0), depositor, 0, emptyDelta, "");
  }

  function test_onlyPoolAdminCanSetDepositors() public {
    vm.prank(admin);
    extension.setAllowedToDeposit(address(pool), depositor, true);
    assertTrue(extension.isAllowedToDeposit(address(pool), depositor));

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(pool), depositor, admin));
    extension.setAllowedToDeposit(address(pool), depositor, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(extension.isAllowedToDeposit(address(pool), depositor));
  }

  function test_passesWhenAllowAllDepositors() public {
    vm.prank(admin);
    extension.setAllowAllDepositors(address(pool), true);
    assertTrue(extension.isAllowedToDeposit(address(pool), depositor));

    vm.prank(address(pool));
    LiquidityDelta memory emptyDelta = LiquidityDelta({binIdxs: new int256[](0), shares: new uint256[](0)});
    extension.beforeAddLiquidity(address(0), depositor, 0, emptyDelta, "");
  }

  function test_onlyPoolAdminCanSetAllowAllDepositors() public {
    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(BaseMetricExtension.OnlyPoolAdmin.selector, address(pool), depositor, admin));
    extension.setAllowAllDepositors(address(pool), true);
  }
}
