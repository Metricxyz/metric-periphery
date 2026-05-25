// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {DepositAllowlistSubhookHarness} from "./SubhookHarness.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

contract DepositAllowlistSubhookTest is Test {
  AllowlistFactoryStub factoryStub;
  DepositAllowlistSubhookHarness harness;

  address admin = makeAddr("admin");
  address depositor = makeAddr("depositor");
  address pool = makeAddr("pool");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    factoryStub.setPoolAdmin(pool, admin);
    harness = new DepositAllowlistSubhookHarness(pool, address(factoryStub));
  }

  function test_revertsWhenDepositorNotAllowed() public {
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    harness.exposeBeforeAddLiquidityAllowlist(depositor);
  }

  function test_passesWhenDepositorAllowed() public {
    vm.prank(admin);
    harness.setAllowedToDeposit(pool, depositor, true);
    harness.exposeBeforeAddLiquidityAllowlist(depositor);
  }

  function test_onlyPoolAdminCanSetDepositors() public {
    vm.prank(admin);
    harness.setAllowedToDeposit(pool, depositor, true);
    assertTrue(harness.isAllowedToDeposit(pool, depositor));

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, pool, depositor, admin));
    harness.setAllowedToDeposit(pool, depositor, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(harness.isAllowedToDeposit(pool, depositor));
  }
}
