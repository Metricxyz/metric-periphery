// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {MetricOmmPoolLiquidityAdder} from "../contracts/MetricOmmPoolLiquidityAdder.sol";
import {PeripheryPayments} from "../contracts/base/PeripheryPayments.sol";
import {MetricOmmPoolLiquidityAdderTest} from "./MetricOmmPoolLiquidityAdder.t.sol";

bytes4 constant ADD_LIQUIDITY_EXACT_SHARES_WITH_OWNER =
  bytes4(keccak256("addLiquidityExactShares(address,address,uint80,(int256[],uint256[]),uint256,uint256,bytes)"));
bytes4 constant ADD_LIQUIDITY_WEIGHTED_WITH_OWNER = bytes4(
  keccak256(
    "addLiquidityWeighted(address,address,uint80,(int256[],uint256[]),uint256,uint256,int8,uint104,int8,uint104,bytes)"
  )
);

/// @dev Native ETH flows follow the same multicall patterns as MetricOmmSimpleRouter:
///      - ETH input: multicall{value}(addLiquidity*) when the pool's WETH leg is token0
///      - unused ETH: refundETH in the same multicall
contract MetricOmmPoolLiquidityAdderNativeTest is MetricOmmPoolLiquidityAdderTest {
  function _assertAdderEmpty() internal view {
    assertEq(address(helper).balance, 0, "adder eth");
    assertEq(weth.balanceOf(address(helper)), 0, "adder weth");
  }

  function test_constructor_revertsOnZeroWeth() public {
    vm.expectRevert(PeripheryPayments.InvalidWETH.selector);
    new MetricOmmPoolLiquidityAdder(address(0));
  }

  function test_receive_acceptsWethWithdraw() public {
    vm.deal(address(weth), 1 ether);
    vm.prank(address(weth));
    (bool ok,) = address(helper).call{value: 1 ether}("");
    assertTrue(ok, "weth withdraw accepted");
    assertEq(address(helper).balance, 1 ether, "adder eth");
  }

  function test_receive_revertsOnDirectEthTransfer() public {
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    vm.expectRevert(PeripheryPayments.NotWETH.selector);
    (bool ok,) = address(helper).call{value: 1 ether}("");
    ok;
  }

  function test_multicall_ethInput_exactShares() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 80_000);

    vm.prank(alice);
    (uint256 need0,) =
      helper.addLiquidityExactShares(address(pool), alice, 19, d, type(uint256).max, type(uint256).max, "");

    uint256 aliceEthBefore = alice.balance;
    uint256 aliceWethBefore = weth.balanceOf(alice);

    vm.prank(alice);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSelector(
      ADD_LIQUIDITY_EXACT_SHARES_WITH_OWNER, address(pool), alice, uint80(20), d, need0, type(uint256).max, ""
    );
    helper.multicall{value: need0}(calls);

    assertGt(stateView.positionBinShares(address(pool), alice, 20, int8(4)), 0, "shares minted");
    assertEq(aliceEthBefore - alice.balance, need0, "alice eth spent");
    assertEq(aliceWethBefore, weth.balanceOf(alice), "alice weth unchanged");
    _assertAdderEmpty();
  }

  function test_mixedNativeAndWeth_exactShares() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 80_000);

    vm.prank(alice);
    (uint256 need0, uint256 need1) =
      helper.addLiquidityExactShares(address(pool), alice, 21, d, type(uint256).max, type(uint256).max, "");

    uint256 nativePart = need0 / 2;
    uint256 wethPart = need0 - nativePart;
    uint256 aliceEthBefore = alice.balance;
    uint256 aliceWethBefore = weth.balanceOf(alice);

    vm.prank(alice);
    helper.addLiquidityExactShares{value: nativePart}(
      address(pool), alice, 22, d, type(uint256).max, type(uint256).max, ""
    );

    assertGt(stateView.positionBinShares(address(pool), alice, 22, int8(4)), 0, "shares minted");
    assertEq(aliceEthBefore - alice.balance, nativePart, "alice native spent");
    assertEq(aliceWethBefore - weth.balanceOf(alice), wethPart, "alice weth spent");
    assertEq(need1, 0, "token1 leg unused in this fixture");
    _assertAdderEmpty();
  }

  function test_multicall_ethInput_refundsUnusedEth() public {
    LiquidityDelta memory d = _deltaAbovePrice(4, 80_000);
    uint256 msgValue = 2 ether;
    uint256 aliceEthBefore = alice.balance;

    vm.prank(alice);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeWithSelector(
      ADD_LIQUIDITY_EXACT_SHARES_WITH_OWNER, address(pool), alice, uint80(23), d, 1_000 ether, 1_000 ether, ""
    );
    calls[1] = abi.encodeWithSelector(helper.refundETH.selector);
    helper.multicall{value: msgValue}(calls);

    assertGt(stateView.positionBinShares(address(pool), alice, 23, int8(4)), 0, "shares minted");
    assertLt(alice.balance, aliceEthBefore, "alice paid for liquidity");
    _assertAdderEmpty();
  }

  function test_multicall_ethInput_weighted() public {
    LiquidityDelta memory w = _deltaAbovePrice(4, 5_000_000);
    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();
    uint256 aliceEthBefore = alice.balance;

    vm.prank(alice);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSelector(
      ADD_LIQUIDITY_WEIGHTED_WITH_OWNER,
      address(pool),
      alice,
      uint80(24),
      w,
      50_000,
      50_000,
      minBin,
      minPos,
      maxBin,
      maxPos,
      ""
    );
    helper.multicall{value: 50_000}(calls);

    assertGt(stateView.positionBinShares(address(pool), alice, 24, int8(4)), 0, "shares minted");
    assertLe(aliceEthBefore - alice.balance, 50_000, "alice eth spent");
    _assertAdderEmpty();
  }
}
