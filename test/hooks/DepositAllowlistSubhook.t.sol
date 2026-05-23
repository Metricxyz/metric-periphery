// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {DepositAllowlistSubhookHarness} from "./SubhookHarness.sol";
import {MetricFactorySubhook} from "../../contracts/hooks/base/MetricFactorySubhook.sol";
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
    harness.setAllowedToDeposit(depositor, true);
    harness.exposeBeforeAddLiquidityAllowlist(depositor);
  }

  function test_onlyPoolAdminCanSetDepositors() public {
    vm.prank(admin);
    harness.setAllowedToDeposit(depositor, true);
    assertTrue(harness.isAllowedToDeposit(depositor));

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(MetricFactorySubhook.OnlyPoolAdmin.selector, pool, depositor, admin));
    harness.setAllowedToDeposit(depositor, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(harness.isAllowedToDeposit(depositor));
  }
}
