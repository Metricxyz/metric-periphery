// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmSimpleRouterFallbackTest} from "./MetricOmmSimpleRouter.fallback.t.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {PinnedAllowanceHolder} from "./mocks/PinnedAllowanceHolder.sol";
import {IAllowanceHolder} from "./vendor/zero-ex/src/allowanceholder/IAllowanceHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Settlement target only; this is not a full 0x Settler/liquidity integration.
contract AllowanceHolderSettlementTarget {
  address public forwardedSender;

  function settle(address holder, address tokenIn, address tokenOut, uint256 spend, uint256 output, address recipient)
    external
  {
    require(msg.sender == holder);
    address sender;
    assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
    forwardedSender = sender;
    IAllowanceHolder(holder).transferFrom(tokenIn, sender, address(this), spend);
    IERC20(tokenOut).transfer(recipient, output);
  }
}

contract MetricOmmSimpleRouterAllowanceHolderTest is MetricOmmSimpleRouterFallbackTest {
  function test_pinnedAllowanceHolderUsesRouterAsOwnerAndClearsAllowance() public {
    PinnedAllowanceHolder holder = new PinnedAllowanceHolder();
    AllowanceHolderSettlementTarget target = new AllowanceHolderSettlementTarget();
    router = new MetricOmmSimpleRouter(address(weth), address(factoryStub), address(holder));
    vm.prank(swapper);
    weth.approve(address(router), type(uint256).max);
    token1.mint(address(target), FALLBACK_OUT);
    bytes memory settlement = abi.encodeCall(
      target.settle, (address(holder), address(weth), address(token1), AMOUNT_IN / 2, FALLBACK_OUT, address(router))
    );
    bytes memory data = abi.encodeCall(
      IAllowanceHolder.exec, (address(target), address(weth), AMOUNT_IN, payable(address(target)), settlement)
    );
    uint256 payerBefore = weth.balanceOf(swapper);
    vm.prank(swapper);
    (uint256 out, bool usedFallback) =
      router.exactInputWithFallback(_params(_primary(address(pool), FALLBACK_OUT, _expired()), data));
    assertTrue(usedFallback);
    assertEq(out, FALLBACK_OUT);
    assertEq(target.forwardedSender(), address(router));
    assertEq(payerBefore - weth.balanceOf(swapper), AMOUNT_IN / 2);
    assertEq(weth.allowance(address(router), address(holder)), 0);
    // Restore ERC20 allowance solely to demonstrate the transient grant was cleared too.
    vm.prank(address(router));
    weth.approve(address(holder), 1);
    vm.prank(address(target));
    vm.expectRevert();
    IAllowanceHolder(address(holder)).transferFrom(address(weth), address(router), address(target), 1);
  }

  function test_pinnedAllowanceHolderCannotBypassOriginalMinimum() public {
    PinnedAllowanceHolder holder = new PinnedAllowanceHolder();
    AllowanceHolderSettlementTarget target = new AllowanceHolderSettlementTarget();
    router = new MetricOmmSimpleRouter(address(weth), address(factoryStub), address(holder));
    vm.prank(swapper);
    weth.approve(address(router), type(uint256).max);
    token1.mint(address(target), FALLBACK_OUT);
    bytes memory data = abi.encodeCall(
      IAllowanceHolder.exec,
      (
        address(target),
        address(weth),
        AMOUNT_IN,
        payable(address(target)),
        abi.encodeCall(
          target.settle, (address(holder), address(weth), address(token1), AMOUNT_IN, FALLBACK_OUT, address(router))
        )
      )
    );
    uint256 payerBefore = weth.balanceOf(swapper);
    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactInputWithFallback(_params(_primary(address(pool), FALLBACK_OUT + 1, _expired()), data));
    assertEq(weth.balanceOf(swapper), payerBefore);
    assertEq(weth.balanceOf(address(target)), 0);
    assertEq(weth.allowance(address(router), address(holder)), 0);
    assertEq(target.forwardedSender(), address(0));
  }
}
