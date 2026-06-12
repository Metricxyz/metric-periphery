// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {DepositAllowlistHook} from "../../contracts/hooks/DepositAllowlistHook.sol";
import {SubhookUtils} from "../../contracts/hooks/base/SubhookUtils.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {MockHookPool} from "./MockHookPool.sol";

contract DepositAllowlistHookTest is Test {
  AllowlistFactoryStub factoryStub;
  DepositAllowlistHook hook;
  MockHookPool pool;

  address admin = makeAddr("admin");
  address depositor = makeAddr("depositor");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    pool = new MockHookPool(address(factoryStub));
    factoryStub.setPoolAdmin(address(pool), admin);
    hook = new DepositAllowlistHook(address(factoryStub));
  }

  function test_revertsWhenDepositorNotAllowed() public {
    vm.prank(address(pool));
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    LiquidityDelta memory emptyDelta = LiquidityDelta({binIdxs: new int256[](0), shares: new uint256[](0)});
    hook.beforeAddLiquidity(address(0), depositor, 0, emptyDelta, "");
  }

  function test_passesWhenDepositorAllowed() public {
    vm.prank(admin);
    hook.setAllowedToDeposit(address(pool), depositor, true);

    vm.prank(address(pool));
    LiquidityDelta memory emptyDelta = LiquidityDelta({binIdxs: new int256[](0), shares: new uint256[](0)});
    hook.beforeAddLiquidity(address(0), depositor, 0, emptyDelta, "");
  }

  function test_onlyPoolAdminCanSetDepositors() public {
    vm.prank(admin);
    hook.setAllowedToDeposit(address(pool), depositor, true);
    assertTrue(hook.isAllowedToDeposit(address(pool), depositor));

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(SubhookUtils.OnlyPoolAdmin.selector, address(pool), depositor, admin));
    hook.setAllowedToDeposit(address(pool), depositor, false);
  }

  function test_deniesByDefault() public view {
    assertFalse(hook.isAllowedToDeposit(address(pool), depositor));
  }
}
