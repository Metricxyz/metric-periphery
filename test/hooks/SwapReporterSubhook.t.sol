// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {SwapReporterSubhookHarness} from "./SubhookHarness.sol";
import {MockSwapReporter} from "./MockSwapReporter.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";

contract SwapReporterSubhookTest is Test {
  AllowlistFactoryStub factoryStub;
  MockSwapReporter reporter;
  SwapReporterSubhookHarness harness;

  address pool = makeAddr("pool");

  function setUp() public {
    factoryStub = new AllowlistFactoryStub();
    reporter = new MockSwapReporter();
    harness = new SwapReporterSubhookHarness(pool, address(factoryStub));
    harness.setPriceProviderOverride(address(reporter));
  }

  function test_reportsSwap() public {
    uint256 packedSlot0Final = Slot0Library.pack(0, 2, 42, 0, 0, 0);

    harness.exposeAfterSwapReport(
      makeAddr("sender"),
      makeAddr("recipient"),
      true,
      int128(1000),
      uint128(123),
      packedSlot0Final,
      int128(-1000),
      int128(900)
    );

    assertEq(reporter.reportCount(), 1);
    assertEq(reporter.lastCurBinIdx(), 2);
    assertEq(reporter.lastCurPosInBin(), 42);
  }

  function test_reporterRevertDoesNotBubble() public {
    reporter.setShouldRevert(true);

    harness.exposeAfterSwapReport(
      makeAddr("sender"), makeAddr("recipient"), false, int128(500), uint128(1), uint256(0), int128(-500), int128(400)
    );

    assertEq(reporter.reportCount(), 0);
  }
}
