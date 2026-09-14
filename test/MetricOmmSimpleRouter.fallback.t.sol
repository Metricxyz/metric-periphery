// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {MockAggregationRouter} from "./mocks/MockAggregationRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmSimpleRouterFallbackTest is SimpleRouterTestBase {
  uint128 internal constant AMOUNT_IN = 2_000;
  uint128 internal constant FALLBACK_OUT = 1_234;
  uint256 internal constant GAS_RESERVE = 300_000;
  address internal constant UNAVAILABLE_POOL = address(0xBAD);

  // ============ Helpers ============

  /// @dev weth -> token1 through `poolAddr`; weth is token0 of `pool`, so the direction bit is set.
  function _primary(address poolAddr, uint128 minOut, uint256 deadline)
    internal
    view
    returns (IMetricOmmSimpleRouter.ExactInputParams memory params)
  {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(token1);

    address[] memory pools = new address[](1);
    pools[0] = poolAddr;

    bytes[] memory extensionDatas = new bytes[](1);
    extensionDatas[0] = "";

    params = IMetricOmmSimpleRouter.ExactInputParams({
      tokens: tokens,
      pools: pools,
      extensionDatas: extensionDatas,
      zeroForOneBitMap: 1,
      amountIn: AMOUNT_IN,
      amountOutMinimum: minOut,
      recipient: recipient,
      deadline: deadline
    });
  }

  /// @dev The aggregator delivers to the router, which forwards to `recipient`.
  function _fallbackCallData(uint256 amountInToPull, uint256 amountOut) internal view returns (bytes memory) {
    return abi.encodeCall(
      MockAggregationRouter.swap, (address(weth), address(token1), amountInToPull, amountOut, address(router))
    );
  }

  function _params(IMetricOmmSimpleRouter.ExactInputParams memory primary, bytes memory callData)
    internal
    view
    returns (IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory)
  {
    return IMetricOmmSimpleRouter.ExactInputWithFallbackParams({
      primary: primary, fallbackCallData: callData, gasReserve: GAS_RESERVE, primaryGasLimit: 500_000
    });
  }

  function _expired() internal view returns (uint256) {
    return block.timestamp - 1;
  }

  // ============ Happy paths ============

  function test_exactInputWithFallback_primaryFillsAndSkipsAggregator() public {
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 wethBefore = weth.balanceOf(swapper);
    uint256 aggregatorWethBefore = weth.balanceOf(address(aggregator));

    vm.prank(swapper);
    (uint256 amountOut, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(address(pool), 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );

    assertFalse(usedFallback, "primary should fill");
    assertGt(amountOut, 0, "amountOut > 0");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "recipient token1");
    assertEq(wethBefore - weth.balanceOf(swapper), AMOUNT_IN, "swapper weth spent once");
    assertEq(weth.balanceOf(address(aggregator)), aggregatorWethBefore, "aggregator untouched");
    assertEq(weth.allowance(address(router), address(aggregator)), 0, "no approval granted");
    _assertRouterEmpty();
  }

  function test_exactInputWithFallback_aggregatorFillsWhenPrimaryUnavailable() public {
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 wethBefore = weth.balanceOf(swapper);
    uint256 aggregatorWethBefore = weth.balanceOf(address(aggregator));

    vm.prank(swapper);
    (uint256 amountOut, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );

    assertTrue(usedFallback, "aggregator should fill");
    assertEq(amountOut, FALLBACK_OUT, "measured aggregator output");
    assertEq(token1.balanceOf(recipient) - token1Before, FALLBACK_OUT, "recipient token1");
    // The reverted primary must not have moved funds: exactly one leg is paid for.
    assertEq(wethBefore - weth.balanceOf(swapper), AMOUNT_IN, "swapper weth spent once");
    assertEq(weth.balanceOf(address(aggregator)) - aggregatorWethBefore, AMOUNT_IN, "aggregator received input");
    assertEq(weth.allowance(address(router), address(aggregator)), 0, "approval reset");
    _assertRouterEmpty();
  }

  function test_exactInputWithFallback_aggregatorFillsWhenPrimaryPoolUnknown() public {
    uint256 token1Before = token1.balanceOf(recipient);

    vm.prank(swapper);
    (uint256 amountOut, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(makeAddr("ghostPool"), 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );

    assertTrue(usedFallback, "aggregator should fill");
    assertEq(token1.balanceOf(recipient) - token1Before, amountOut, "recipient token1");
    _assertRouterEmpty();
  }

  /// @dev A leg that spends less than it was approved must return the remainder to the payer.
  function test_exactInputWithFallback_refundsUnspentInput() public {
    uint128 partialSpend = AMOUNT_IN / 4;
    uint256 wethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    (, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(partialSpend, FALLBACK_OUT))
    );

    assertTrue(usedFallback, "aggregator should fill");
    assertEq(wethBefore - weth.balanceOf(swapper), partialSpend, "only the spent input is debited");
    _assertRouterEmpty();
  }

  // ============ Failure paths ============

  function test_exactInputWithFallback_revertsBothRoutesFailed() public {
    aggregator.setShouldRevert(true);

    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
  }

  /// @dev The primary's minimum guards the aggregator leg too: one slippage figure covers whichever leg settles.
  function test_exactInputWithFallback_primaryMinimumGuardsAggregatorLeg() public {
    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, FALLBACK_OUT + 1, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
  }

  function test_exactInputWithFallback_revertsEmptyFallbackCallData() public {
    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.EmptyFallbackCallData.selector);
    router.exactInputWithFallback(_params(_primary(address(pool), 0, _deadline()), ""));
  }

  function test_exactInputWithFallback_revertsFallbackRouterNotSet() public {
    MetricOmmSimpleRouter unset = new MetricOmmSimpleRouter(address(weth), address(factoryStub), address(0));

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.FallbackRouterNotSet.selector);
    unset.exactInputWithFallback(
      _params(_primary(address(pool), 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
  }

  function test_exactInputWithFallback_revertsInsufficientGasReserve() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(address(pool), 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    params.gasReserve = type(uint256).max;

    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.InsufficientGasReserve.selector);
    router.exactInputWithFallback(params);
  }

  function test_exactInputWithFallback_revertsExpiredOriginalDeadline() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    params.primary.deadline = _expired();

    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.TransactionExpired.selector, params.primary.deadline, block.timestamp
      )
    );
    router.exactInputWithFallback(params);
  }

  function test_exactOutputWithFallback_revertsExpiredOriginalDeadline() public {
    IMetricOmmSimpleRouter.ExactOutputWithFallbackParams memory params =
      _paramsOut(_primaryOut(UNAVAILABLE_POOL, MAX_IN, _expired()), _fallbackCallData(MAX_IN, EXACT_OUT));
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.TransactionExpired.selector, params.primary.deadline, block.timestamp
      )
    );
    router.exactOutputWithFallback(params);
  }

  function test_exactInputOriginalDeadlineBoundaryAllowsEitherRoute() public {
    for (uint256 i; i < 2; ++i) {
      IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params = _params(
        _primary(i == 0 ? address(pool) : UNAVAILABLE_POOL, FALLBACK_OUT, block.timestamp),
        _fallbackCallData(AMOUNT_IN, FALLBACK_OUT)
      );
      vm.prank(swapper);
      (uint256 out, bool usedFallback) = router.exactInputWithFallback(params);
      assertEq(usedFallback, i == 1);
      assertGe(out, FALLBACK_OUT);
    }
    _assertRouterEmpty();
  }

  function test_exactOutputOriginalDeadlineBoundaryAllowsEitherRoute() public {
    for (uint256 i; i < 2; ++i) {
      IMetricOmmSimpleRouter.ExactOutputWithFallbackParams memory params = _paramsOut(
        _primaryOut(i == 0 ? address(pool) : UNAVAILABLE_POOL, MAX_IN, block.timestamp),
        _fallbackCallData(MAX_IN, EXACT_OUT)
      );
      vm.prank(swapper);
      (uint256 spent, bool usedFallback) = router.exactOutputWithFallback(params);
      assertEq(usedFallback, i == 1);
      assertLe(spent, MAX_IN);
    }
    _assertRouterEmpty();
  }

  function test_exactInputAttempt_revertsOnlySelf() public {
    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.OnlySelf.selector);
    router.exactInputAttempt(_primary(address(pool), 0, _deadline()), swapper);
  }

  function test_fallbackSwapAttempt_revertsOnlySelf() public {
    IMetricOmmSimpleRouter.FallbackSwapTerms memory terms = IMetricOmmSimpleRouter.FallbackSwapTerms({
      tokenIn: address(weth),
      tokenOut: address(token1),
      recipient: recipient,
      payer: swapper,
      amountIn: AMOUNT_IN,
      amountOutMinimum: 0,
      deadline: _deadline()
    });

    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.OnlySelf.selector);
    router.fallbackSwapAttempt(terms, _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
  }

  function test_sameCalldataUsesFallbackBeforeOracleUpdateAndPrimaryAfter() public {
    oracle.setBidAndAskPrice(uint128(Q64 / 2), uint128(Q64 / 2 + 1));
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(address(pool), 1_500, _deadline()), _fallbackCallData(AMOUNT_IN, 1_600));
    uint256 snapshot = vm.snapshotState();
    vm.prank(swapper);
    (uint256 fallbackOut, bool fallbackUsed) = router.exactInputWithFallback(params);
    assertTrue(fallbackUsed);
    assertEq(fallbackOut, 1_600);
    assertTrue(vm.revertToState(snapshot));
    oracle.setBidAndAskPrice(TEST_BID_X64, TEST_ASK_X64);
    vm.prank(swapper);
    (uint256 primaryOut, bool usedFallback) = router.exactInputWithFallback(params);
    assertFalse(usedFallback);
    assertGt(primaryOut, fallbackOut);
    _assertRouterEmpty();
  }

  function test_primaryTransfersRollbackWhenMinimumFails() public {
    // The primary transfers output and pays its callback before checking the minimum.
    uint256 poolIn = weth.balanceOf(address(pool));
    uint256 poolOut = token1.balanceOf(address(pool));
    uint256 payerIn = weth.balanceOf(swapper);
    uint256 recipientOut = token1.balanceOf(recipient);
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(address(pool), 3_000, _deadline()), _fallbackCallData(AMOUNT_IN, 3_000))
    );
    assertTrue(usedFallback);
    assertEq(out, 3_000);
    assertEq(weth.balanceOf(address(pool)), poolIn);
    assertEq(token1.balanceOf(address(pool)), poolOut);
    assertEq(payerIn - weth.balanceOf(swapper), AMOUNT_IN);
    assertEq(token1.balanceOf(recipient) - recipientOut, 3_000);
    _assertRouterEmpty();
  }

  function test_insufficientOuterGasCannotSilentlySelectFallback() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.InsufficientGasReserve.selector);
    router.exactInputWithFallback{gas: 600_000}(params);
  }

  function test_zeroPrimaryBudgetRejected() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(address(pool), 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    params.primaryGasLimit = 0;
    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.InvalidPrimaryGasLimit.selector);
    router.exactInputWithFallback(params);
  }

  function test_primaryOutOfGasRetainsFallbackBudget() public {
    address burner = address(new GasBurningFallbackPool());
    vm.mockCall(address(factoryStub), abi.encodeWithSignature("isPool(address)", burner), abi.encode(true));
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback{gas: 900_000}(
      _params(_primary(burner, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
    assertTrue(usedFallback);
    assertEq(out, FALLBACK_OUT);
    _assertRouterEmpty();
  }

  function test_largePrimaryRevertRetainsFallbackBudget() public {
    address bomber = address(new RevertDataFallbackPool());
    vm.mockCall(address(factoryStub), abi.encodeWithSignature("isPool(address)", bomber), abi.encode(true));
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback{gas: 900_000}(
      _params(_primary(bomber, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
    assertTrue(usedFallback);
    assertEq(out, FALLBACK_OUT);
  }

  function test_primaryRevertDiagnosticIsBounded() public {
    address bomber = address(new RevertDataFallbackPool());
    vm.mockCall(address(factoryStub), abi.encodeWithSignature("isPool(address)", bomber), abi.encode(true));
    aggregator.setShouldRevert(true);
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.BothRoutesFailed.selector,
        new bytes(4096),
        abi.encodeWithSelector(MockAggregationRouter.MockAggregatorReverted.selector)
      )
    );
    router.exactInputWithFallback{gas: 900_000}(
      _params(_primary(bomber, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
  }

  function test_nativeFallbackRefundsUnspentWrappedInput() public {
    uint256 payerWeth = weth.balanceOf(swapper);
    uint256 payerEth = swapper.balance;
    vm.prank(swapper);
    (, bool usedFallback) = router.exactInputWithFallback{value: AMOUNT_IN}(
      _params(_primary(UNAVAILABLE_POOL, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN / 2, FALLBACK_OUT))
    );
    assertTrue(usedFallback);
    assertEq(swapper.balance, payerEth - AMOUNT_IN);
    assertEq(weth.balanceOf(swapper), payerWeth + AMOUNT_IN / 2);
    _assertRouterEmpty();
  }

  function test_fallbackIgnoresLargeSuccessfulReturnData() public {
    aggregator.setResponse(200_000, false);
    uint256 beforeOut = token1.balanceOf(recipient);
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
    assertTrue(usedFallback);
    assertEq(out, FALLBACK_OUT);
    assertEq(token1.balanceOf(recipient) - beforeOut, FALLBACK_OUT);
    assertEq(weth.allowance(address(router), address(aggregator)), 0);
    _assertRouterEmpty();
  }

  function _assertFallbackRevertData(uint256 size) internal {
    aggregator.setResponse(size, true);
    bytes memory expected;
    if (size == 0) {
      expected = abi.encodeWithSelector(IMetricOmmSimpleRouter.FallbackCallFailed.selector);
    } else {
      expected = new bytes(size > 4096 ? 4096 : size);
      // The mock prefixes its zero-filled response with this marker.
      assembly ("memory-safe") { mstore(add(expected, 0x20), 0xdeadbeef) }
    }
    uint256 payerBefore = weth.balanceOf(swapper);
    uint256 recipientBefore = token1.balanceOf(recipient);
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.BothRoutesFailed.selector,
        abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, UNAVAILABLE_POOL),
        expected
      )
    );
    router.exactInputWithFallback(
      _params(_primary(UNAVAILABLE_POOL, FALLBACK_OUT, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT))
    );
    assertEq(weth.balanceOf(swapper), payerBefore);
    assertEq(token1.balanceOf(recipient), recipientBefore);
    assertEq(weth.allowance(address(router), address(aggregator)), 0);
    _assertRouterEmpty();
  }

  function test_fallbackRevertDataIsBounded() public {
    _assertFallbackRevertData(200_000);
  }

  function test_fallbackSmallRevertDataIsPreserved() public {
    _assertFallbackRevertData(64);
  }

  function test_fallbackEmptyRevertUsesCustomError() public {
    _assertFallbackRevertData(0);
  }

  function test_primaryCycleStillExecutesWithoutFallback() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(address(pool), 1, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    params.primary.tokens = new address[](3);
    params.primary.tokens[0] = address(weth);
    params.primary.tokens[1] = address(token1);
    params.primary.tokens[2] = address(weth);
    params.primary.pools = new address[](2);
    params.primary.pools[0] = address(pool);
    params.primary.pools[1] = address(pool);
    params.primary.extensionDatas = new bytes[](2);
    // First hop token0 -> token1, second hop token1 -> token0.
    params.primary.zeroForOneBitMap = 1;
    uint256 recipientBefore = weth.balanceOf(recipient);
    vm.prank(swapper);
    (uint256 out, bool usedFallback) = router.exactInputWithFallback(params);
    assertFalse(usedFallback);
    assertGt(out, 0);
    assertEq(weth.balanceOf(recipient) - recipientBefore, out);
    _assertRouterEmpty();
  }

  function test_exactInputFallbackRejectsSameTokenPair() public {
    IMetricOmmSimpleRouter.ExactInputWithFallbackParams memory params =
      _params(_primary(UNAVAILABLE_POOL, 0, _deadline()), _fallbackCallData(AMOUNT_IN, FALLBACK_OUT));
    params.primary.tokens[1] = params.primary.tokens[0];
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.BothRoutesFailed.selector,
        abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, UNAVAILABLE_POOL),
        abi.encodeWithSelector(IMetricOmmSimpleRouter.SameTokenFallback.selector)
      )
    );
    router.exactInputWithFallback(params);
  }

  function test_exactOutputFallbackRejectsSameTokenPair() public {
    IMetricOmmSimpleRouter.ExactOutputWithFallbackParams memory params =
      _paramsOut(_primaryOut(UNAVAILABLE_POOL, MAX_IN, _deadline()), _fallbackCallData(MAX_IN, EXACT_OUT));
    params.primary.tokens[1] = params.primary.tokens[0];
    vm.prank(swapper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSimpleRouter.BothRoutesFailed.selector,
        abi.encodeWithSelector(IMetricOmmSimpleRouter.InvalidPool.selector, UNAVAILABLE_POOL),
        abi.encodeWithSelector(IMetricOmmSimpleRouter.SameTokenFallback.selector)
      )
    );
    router.exactOutputWithFallback(params);
  }

  // ============ Exact output ============

  uint128 internal constant EXACT_OUT = 1_500;
  uint128 internal constant MAX_IN = 10_000;

  /// @dev weth -> token1 through `poolAddr`, buying exactly `EXACT_OUT` of token1.
  function _primaryOut(address poolAddr, uint128 amountInMax, uint256 deadline)
    internal
    view
    returns (IMetricOmmSimpleRouter.ExactOutputParams memory params)
  {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(token1);

    address[] memory pools = new address[](1);
    pools[0] = poolAddr;

    bytes[] memory extensionDatas = new bytes[](1);
    extensionDatas[0] = "";

    params = IMetricOmmSimpleRouter.ExactOutputParams({
      tokens: tokens,
      pools: pools,
      extensionDatas: extensionDatas,
      zeroForOneBitMap: 1,
      amountOut: EXACT_OUT,
      amountInMaximum: amountInMax,
      recipient: recipient,
      deadline: deadline
    });
  }

  function _paramsOut(IMetricOmmSimpleRouter.ExactOutputParams memory primary, bytes memory callData)
    internal
    view
    returns (IMetricOmmSimpleRouter.ExactOutputWithFallbackParams memory)
  {
    return IMetricOmmSimpleRouter.ExactOutputWithFallbackParams({
      primary: primary, fallbackCallData: callData, gasReserve: GAS_RESERVE, primaryGasLimit: 500_000
    });
  }

  function test_exactOutputWithFallback_primaryFillsAndSkipsAggregator() public {
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 aggregatorWethBefore = weth.balanceOf(address(aggregator));

    vm.prank(swapper);
    (uint256 amountIn, bool usedFallback) = router.exactOutputWithFallback(
      _paramsOut(_primaryOut(address(pool), MAX_IN, _deadline()), _fallbackCallData(MAX_IN, EXACT_OUT))
    );

    assertFalse(usedFallback, "primary should fill");
    assertGt(amountIn, 0, "amountIn > 0");
    assertLe(amountIn, MAX_IN, "amountIn <= max");
    assertEq(token1.balanceOf(recipient) - token1Before, EXACT_OUT, "exact token1 out");
    assertEq(weth.balanceOf(address(aggregator)), aggregatorWethBefore, "aggregator untouched");
    _assertRouterEmpty();
  }

  /// @dev The aggregator leg reports what it actually spent, which is the exact-output `amountIn`.
  function test_exactOutputWithFallback_aggregatorFillsWhenPrimaryUnavailable() public {
    uint128 actualSpend = MAX_IN / 2;
    uint256 token1Before = token1.balanceOf(recipient);
    uint256 wethBefore = weth.balanceOf(swapper);

    vm.prank(swapper);
    (uint256 amountIn, bool usedFallback) = router.exactOutputWithFallback(
      _paramsOut(_primaryOut(UNAVAILABLE_POOL, MAX_IN, _deadline()), _fallbackCallData(actualSpend, EXACT_OUT))
    );

    assertTrue(usedFallback, "aggregator should fill");
    assertEq(amountIn, actualSpend, "reported amountIn is the real spend, not the cap");
    assertEq(token1.balanceOf(recipient) - token1Before, EXACT_OUT, "recipient gets exactly amountOut");
    assertEq(wethBefore - weth.balanceOf(swapper), actualSpend, "unspent cap refunded to payer");
    assertEq(weth.allowance(address(router), address(aggregator)), 0, "approval reset");
    _assertRouterEmpty();
  }

  /// @dev `primary.amountOut` is a floor on the aggregator leg: an underdelivering leg must not settle.
  function test_exactOutputWithFallback_exactOutGuardsAggregatorLeg() public {
    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactOutputWithFallback(
      _paramsOut(_primaryOut(UNAVAILABLE_POOL, MAX_IN, _deadline()), _fallbackCallData(MAX_IN, EXACT_OUT - 1))
    );
  }

  function test_exactOutputWithFallback_revertsBothRoutesFailed() public {
    aggregator.setShouldRevert(true);

    vm.prank(swapper);
    vm.expectPartialRevert(IMetricOmmSimpleRouter.BothRoutesFailed.selector);
    router.exactOutputWithFallback(
      _paramsOut(_primaryOut(UNAVAILABLE_POOL, MAX_IN, _deadline()), _fallbackCallData(MAX_IN, EXACT_OUT))
    );
  }

  function test_exactOutputWithFallback_revertsEmptyFallbackCallData() public {
    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.EmptyFallbackCallData.selector);
    router.exactOutputWithFallback(_paramsOut(_primaryOut(address(pool), MAX_IN, _deadline()), ""));
  }

  function test_exactOutputAttempt_revertsOnlySelf() public {
    vm.prank(swapper);
    vm.expectRevert(IMetricOmmSimpleRouter.OnlySelf.selector);
    router.exactOutputAttempt(_primaryOut(address(pool), MAX_IN, _deadline()), swapper);
  }
}

contract GasBurningFallbackPool {
  fallback() external {
    assembly { invalid() }
  }
}

contract RevertDataFallbackPool {
  fallback() external {
    assembly { revert(0x80, 200000) }
  }
}
