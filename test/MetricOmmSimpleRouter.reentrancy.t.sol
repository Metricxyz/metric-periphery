// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {IPeripheryPayments} from "../contracts/interfaces/IPeripheryPayments.sol";
import {PinnedAllowanceHolder} from "./mocks/PinnedAllowanceHolder.sol";
import {IAllowanceHolder} from "./vendor/zero-ex/src/allowanceholder/IAllowanceHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract RouterReentryTarget {
  address public immutable router;
  bytes[] private probes;
  uint256 public blocked;

  constructor(address router_) {
    router = router_;
  }

  function configure(bytes[] memory probes_) external {
    probes = probes_;
  }

  function probe() public {
    for (uint256 i; i < probes.length; ++i) {
      (bool success, bytes memory reason) = router.call(probes[i]);
      require(
        !success
          && keccak256(reason)
            == keccak256(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)),
        "reentry was not rejected by execution lock"
      );
      ++blocked;
    }
  }

  function settle(address holder, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
    require(msg.sender == holder);
    probe();
    IAllowanceHolder(holder).transferFrom(tokenIn, router, address(this), amountIn);
    IERC20(tokenOut).transfer(router, amountOut);
  }

  function claimRefund() external {
    IPeripheryPayments(router).refundETH();
  }

  receive() external payable {
    probe();
  }

  // Fake ERC20/permit surfaces to exercise arbitrary token calls made by payment and permit helpers.

  function allowance(address, address) external pure returns (uint256) {
    return 0;
  }

  function transfer(address, uint256) external returns (bool) {
    probe();
    return true;
  }

  fallback() external virtual {
    revert("unsupported call");
  }
}

contract RouterReentryToken is RouterReentryTarget {
  constructor(address router_) RouterReentryTarget(router_) {}

  function balanceOf(address) external pure returns (uint256) {
    return 1;
  }

  fallback() external override {
    probe();
  }
}

contract MetricOmmSimpleRouterReentrancyTest is SimpleRouterTestBase {
  PinnedAllowanceHolder internal holder;
  RouterReentryTarget internal attacker;

  function setUp() public override {
    super.setUp();
    holder = new PinnedAllowanceHolder();
    router = new MetricOmmSimpleRouter(address(weth), address(factoryStub), address(holder));
    attacker = new RouterReentryTarget(address(router));
    token1.mint(address(attacker), 1_000_000);
    vm.prank(swapper);
    weth.approve(address(router), type(uint256).max);
  }

  function _primary(uint256 deadline) internal view returns (IMetricOmmSimpleRouter.ExactInputParams memory p) {
    p.tokens = new address[](2);
    p.tokens[0] = address(weth);
    p.tokens[1] = address(token1);
    p.pools = new address[](1);
    p.pools[0] = address(pool);
    p.extensionDatas = new bytes[](1);
    p.zeroForOneBitMap = 1;
    p.amountIn = 2_000;
    p.amountOutMinimum = 1_000;
    p.recipient = recipient;
    p.deadline = deadline;
  }

  function _fallbackParams() internal view returns (IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory p) {
    p.primary = _primary(block.timestamp - 1);
    p.fallbackDeadline = _deadline();
    p.primaryGasLimit = 500_000;
    p.gasReserve = 1_000_000;
    p.fallbackCallData = abi.encodeCall(
      IAllowanceHolder.exec,
      (
        address(attacker),
        address(weth),
        2_000,
        payable(address(attacker)),
        abi.encodeCall(attacker.settle, (address(holder), address(weth), address(token1), 2_000, 1_000))
      )
    );
  }

  function _paymentProbes() internal view returns (bytes[] memory probes) {
    probes = new bytes[](3);
    probes[0] = abi.encodeCall(router.refundETH, ());
    probes[1] = abi.encodeCall(router.sweepToken, (address(token1), 0, address(attacker)));
    probes[2] = abi.encodeCall(router.unwrapWETH9, (0, address(attacker)));
  }

  function test_allowanceHolderCannotReenterAnySwapOrPaymentEntrypoint() public {
    bytes[] memory probes = new bytes[](14);
    bytes[] memory payments = _paymentProbes();
    for (uint256 i; i < 3; ++i) {
      probes[i] = payments[i];
    }
    IMetricOmmSimpleRouter.ExactInputSingleParams memory inputSingle;
    IMetricOmmSimpleRouter.ExactOutputSingleParams memory outputSingle;
    IMetricOmmSimpleRouter.ExactOutputParams memory output;
    IMetricOmmSimpleRouter.ExactOutputWithFallbackParams memory outputFallback;
    probes[3] = abi.encodeCall(router.exactInputSingle, (inputSingle));
    probes[4] = abi.encodeCall(router.exactInput, (_primary(_deadline())));
    probes[5] = abi.encodeCall(router.exactInputWithFallback, (_fallbackParams()));
    probes[6] = abi.encodeCall(router.exactOutputSingle, (outputSingle));
    probes[7] = abi.encodeCall(router.exactOutput, (output));
    probes[8] = abi.encodeCall(router.exactOutputWithFallback, (outputFallback));
    probes[9] = abi.encodeCall(router.multicall, (payments));
    probes[10] = abi.encodeCall(router.selfPermit, (address(attacker), 1, _deadline(), 0, bytes32(0), bytes32(0)));
    probes[11] =
      abi.encodeCall(router.selfPermitAllowed, (address(attacker), 0, _deadline(), 0, bytes32(0), bytes32(0)));
    probes[12] =
      abi.encodeCall(router.selfPermitIfNecessary, (address(attacker), 1, _deadline(), 0, bytes32(0), bytes32(0)));
    probes[13] = abi.encodeCall(
      router.selfPermitAllowedIfNecessary, (address(attacker), 0, _deadline(), 0, bytes32(0), bytes32(0))
    );
    attacker.configure(probes);
    // These balances would be exposed to refund/sweep/unwrap during the external call without the lock.
    token1.mint(address(router), 777);
    vm.prank(swapper);
    weth.transfer(address(router), 555);
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback{value: 12_000}(_fallbackParams());
    assertTrue(usedFallback);
    assertEq(out, 1_000);
    assertEq(attacker.blocked(), probes.length);
    assertEq(address(attacker).balance, 0);
    assertEq(address(router).balance, 10_000);
    assertEq(token1.balanceOf(address(router)), 777);
    assertEq(weth.balanceOf(address(router)), 555);
    assertEq(weth.allowance(address(router), address(holder)), 0);
    assertEq(token1.balanceOf(recipient), out);
  }

  function test_multicallFallbackThenPrimaryThenPaymentsUnlocksBetweenOperations() public {
    attacker.configure(_paymentProbes());
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory fallbackParams = _fallbackParams();
    fallbackParams.primary.recipient = address(router);
    IMetricOmmSimpleRouter.ExactInputParams memory primary = _primary(_deadline());
    primary.recipient = address(router);
    bytes[] memory calls = new bytes[](5);
    calls[0] = abi.encodeCall(router.exactInputWithFallback, (fallbackParams));
    calls[1] = abi.encodeCall(router.exactInput, (primary));
    calls[2] = abi.encodeCall(router.sweepToken, (address(token1), 1_000, recipient));
    calls[3] = abi.encodeCall(router.unwrapWETH9, (0, recipient));
    calls[4] = abi.encodeCall(router.refundETH, ());
    uint256 ethBefore = swapper.balance;
    vm.prank(swapper);
    bytes[] memory results = router.multicall{value: 10_000}(calls);
    (, bool usedFallback) = abi.decode(results[0], (uint256, bool));
    assertTrue(usedFallback);
    assertEq(attacker.blocked(), 3);
    assertEq(ethBefore - swapper.balance, 4_000);
    assertGt(token1.balanceOf(recipient), 1_000);
    _assertRouterEmpty();
  }

  function test_paymentRecipientsAndTokensCannotReenter() public {
    attacker.configure(_paymentProbes());
    token1.mint(address(router), 777);
    vm.deal(address(router), 1_000);
    attacker.claimRefund();
    assertEq(attacker.blocked(), 3);
    assertEq(address(attacker).balance, 1_000);
    vm.prank(swapper);
    weth.transfer(address(router), 500);
    router.unwrapWETH9(500, address(attacker));
    assertEq(attacker.blocked(), 6);
    assertEq(address(attacker).balance, 1_500);
    RouterReentryToken token = new RouterReentryToken(address(router));
    token.configure(_paymentProbes());
    router.sweepToken(address(token), 1, recipient);
    assertEq(token.blocked(), 3);
    assertEq(token1.balanceOf(address(router)), 777);
    router.sweepToken(address(token1), 777, recipient);
    _assertRouterEmpty();
  }

  function test_permitCallsCannotStealMulticallETH() public {
    RouterReentryToken token = new RouterReentryToken(address(router));
    token.configure(_paymentProbes());
    bytes[] memory calls = new bytes[](5);
    calls[0] = abi.encodeCall(router.selfPermit, (address(token), 1, _deadline(), 0, bytes32(0), bytes32(0)));
    calls[1] = abi.encodeCall(router.selfPermitIfNecessary, (address(token), 1, _deadline(), 0, bytes32(0), bytes32(0)));
    calls[2] = abi.encodeCall(router.selfPermitAllowed, (address(token), 0, _deadline(), 0, bytes32(0), bytes32(0)));
    calls[3] =
      abi.encodeCall(router.selfPermitAllowedIfNecessary, (address(token), 0, _deadline(), 0, bytes32(0), bytes32(0)));
    calls[4] = abi.encodeCall(router.refundETH, ());
    uint256 beforeEth = swapper.balance;
    vm.prank(swapper);
    router.multicall{value: 10_000}(calls);
    assertEq(token.blocked(), 12);
    assertEq(swapper.balance, beforeEth);
    assertEq(address(token).balance, 0);
    _assertRouterEmpty();
  }

  function test_failedSwapDoesNotLeaveLockSet() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory p = _fallbackParams();
    p.primary.amountOutMinimum = 5_000;
    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactInputWithFallback(p);
    vm.prank(swapper);
    uint256 out = router.exactInput(_primary(_deadline()));
    assertGt(out, 1_000);
    _assertRouterEmpty();
  }
}
