// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DepositAllowlist} from "../contracts/DepositAllowlist.sol";
import {SwapAllowlist} from "../contracts/SwapAllowlist.sol";
import {AllowlistFactoryStub} from "./AllowlistFactoryStub.sol";

contract AllowlistTest is Test {
  AllowlistFactoryStub factoryStub;
  DepositAllowlist depositAllowlist;
  SwapAllowlist swapAllowlist;

  address admin = makeAddr("admin");
  address other = makeAddr("other");
  address pool = makeAddr("pool");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    depositAllowlist = new DepositAllowlist(address(factoryStub));
    swapAllowlist = new SwapAllowlist(address(factoryStub));
    factoryStub.setPoolAdmin(pool, admin);
  }

  function test_depositAllowlist_onlyPoolAdminCanSetDepositors() public {
    vm.prank(admin);
    depositAllowlist.setAllowedToDeposit(pool, other, true);
    assertTrue(depositAllowlist.isAllowedToDeposit(pool, other));

    vm.prank(other);
    vm.expectRevert(abi.encodeWithSelector(DepositAllowlist.OnlyPoolAdmin.selector, pool, other, admin));
    depositAllowlist.setAllowedToDeposit(pool, other, false);
  }

  function test_swapAllowlist_onlyPoolAdminCanSetSwappers() public {
    vm.prank(admin);
    swapAllowlist.setAllowedToSwap(pool, other, true);
    assertTrue(swapAllowlist.isAllowedToSwap(pool, other));

    vm.prank(other);
    vm.expectRevert(abi.encodeWithSelector(SwapAllowlist.OnlyPoolAdmin.selector, pool, other, admin));
    swapAllowlist.setAllowedToSwap(pool, other, false);
  }

  function test_depositAllowlist_deniesByDefault() public view {
    assertFalse(depositAllowlist.isAllowedToDeposit(pool, other));
  }

  function test_swapAllowlist_deniesByDefault() public view {
    assertFalse(swapAllowlist.isAllowedToSwap(pool, other));
  }
}
