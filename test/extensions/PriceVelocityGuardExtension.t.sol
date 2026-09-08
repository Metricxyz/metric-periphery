// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {IPriceVelocityGuardExtension} from "../../contracts/interfaces/extensions/IPriceVelocityGuardExtension.sol";
import {MockExtensionPool} from "./MockExtensionPool.sol";
import {PriceVelocityGuardExtension} from "../../contracts/extensions/PriceVelocityGuardExtension.sol";

contract PriceVelocityGuardExtensionTest is Test {
  AllowlistFactoryStub factoryStub;
  PriceVelocityGuardExtension extension;
  MockExtensionPool pool;

  address admin = makeAddr("admin");

  uint128 constant ANCHOR = 100e18;
  uint64 constant ONE_PCT = 0.01e18;

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    pool = new MockExtensionPool(address(factoryStub));
    factoryStub.setPoolAdmin(address(pool), admin);
    extension = new PriceVelocityGuardExtension(address(factoryStub));

    vm.prank(admin);
    extension.setMaxChangePerBlock(address(pool), ONE_PCT);
    vm.prank(admin);
    extension.setAnchorMidPrice(address(pool), ANCHOR);
  }

  function _beforeSwap(uint128 midPriceX64) internal {
    vm.prank(address(pool));
    extension.beforeSwap(address(0), address(0), true, 0, 0, 0, 0, 0, midPriceX64, "");
  }

  function test_secondIdenticalSwapInSameBlockUsesSameAllowanceAsFirst() public {
    vm.roll(block.number + 3);
    uint128 quote = uint128((uint256(ANCHOR) * 1015) / 1000);

    _beforeSwap(quote);
    _beforeSwap(quote);
  }

  function test_thirdSwapInSameBlockStillRespectsOriginalAnchor() public {
    vm.roll(block.number + 3);
    uint128 withinBudget = uint128((uint256(ANCHOR) * 1015) / 1000);
    uint128 beyondBudget = uint128((uint256(ANCHOR) * 1025) / 1000);

    _beforeSwap(withinBudget);
    _beforeSwap(withinBudget);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPriceVelocityGuardExtension.PriceVelocityExceeded.selector, 0.025e18 * 0.025e18, 0.01e18 * 0.01e18 * 4
      )
    );
    _beforeSwap(beyondBudget);
  }

  function test_newBlockRollsAnchorToLastObservedPrice() public {
    vm.roll(block.number + 3);
    uint128 firstBlockPrice = uint128((uint256(ANCHOR) * 1015) / 1000);
    _beforeSwap(firstBlockPrice);

    vm.roll(block.number + 1);
    uint128 nextBlockPrice = uint128((uint256(firstBlockPrice) * 1005) / 1000);
    _beforeSwap(nextBlockPrice);
  }
}
