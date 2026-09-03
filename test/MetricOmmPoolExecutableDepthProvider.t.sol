// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {MetricOmmPoolExecutableDepthProvider} from "../contracts/lens/MetricOmmPoolExecutableDepthProvider.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";
import {
  LiquiditySeederForSwapData,
  MetricOmmPoolDataProviderTestBase,
  MockPriceProviderSDH
} from "./MetricOmmPoolDataProviderTestBase.sol";

/// @notice `getExecutableLiquidityDepth` — the executable prefix of a published depth curve.
/// @dev The refusal cases mock `simulateSwapAndRevert` for the *specific* probe calldata a level
///      produces, rather than standing up an extension-bearing pool. That keeps the assertions on the
///      search itself — which level a refusal truncates to, and how many probes it costs — and it lets a
///      test express "refuses above size X", which is the shape an `OracleValueStopLoss` actually has.
contract MetricOmmPoolExecutableDepthProviderTest is MetricOmmPoolDataProviderTestBase {
  uint256 internal constant DEEP_SHARES = SHARES_PER_BIN / 5_000;
  uint8 internal constant WINDOW = 16;

  /// @dev Arbitrary refusal payload. The classifier keys on "is this `SimulateSwap`", so the selector
  ///      only has to be something else — mirroring the real StopLoss error, which is published nowhere.
  bytes internal constant REFUSAL = abi.encodeWithSelector(bytes4(0x4590ac6a), 0, 1, 974_133, 1_024_138);

  MetricOmmPool internal pool;
  MockPriceProviderSDH internal oracle;
  MockERC20 internal token0;
  MockERC20 internal token1;
  MetricOmmPoolDataProvider internal helper;
  MetricOmmSimpleRouter internal router;
  RouterTestFactory internal factory;
  LiquiditySeederForSwapData internal seeder;

  MetricOmmPoolExecutableDepthProvider internal lens;

  function setUp() public {
    (pool, oracle, token0, token1, helper, router, factory, seeder) =
      _deployCase(18, 18, _toX64(990_000), _toX64(1_010_000), 0, DEEP_SHARES, true);
    lens = new MetricOmmPoolExecutableDepthProvider(address(factory));
  }

  // ============ Happy path ============

  /// A pool with nothing intercepting its swaps publishes its whole curve, and says so in one probe
  /// per side. That single probe is the point: the search tries the deepest level first, so the
  /// common case never pays for the halving.
  function test_unobstructedPool_isFullyExecutable_inOneProbePerSide() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertGt(out.depth.asks.length, 0, "expected a published ask side");
    assertGt(out.depth.bids.length, 0, "expected a published bid side");
    assertEq(out.asksExecutableLevels, out.depth.asks.length, "ask side should be fully executable");
    assertEq(out.bidsExecutableLevels, out.depth.bids.length, "bid side should be fully executable");
    assertEq(out.asksProbes, 1, "deepest level executed, so no halving should have happened");
    assertEq(out.bidsProbes, 1);
  }

  /// The curve itself is untouched — this contract reports where to cut, it does not cut.
  function test_depthMatchesTheBaseProvider() public {
    MetricOmmPoolDataProvider.LiquidityDepth memory expected = helper.getLiquidityDepth(address(pool), WINDOW);
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.depth.asks.length, expected.asks.length);
    assertEq(out.depth.bids.length, expected.bids.length);
    assertEq(out.depth.oracleBidX64, expected.oracleBidX64);
    assertEq(out.depth.oracleAskX64, expected.oracleAskX64);
    assertEq(out.depth.oracleReferenceX64, expected.oracleReferenceX64);
  }

  // ============ Refusal ============

  /// A pool that refuses everything reports a closed side, not a trimmed one. This is the AERO buy
  /// side: refused at the smallest size we could ask about.
  function test_refusingEveryLevel_closesTheSide() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    _refuseAsksAtOrAbove(published.depth, 0);

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.asksExecutableLevels, 0, "no level executes, so the side is closed");
    assertEq(out.bidsExecutableLevels, out.depth.bids.length, "the other side is unaffected");
  }

  /// The AERO sell side: the shallowest level executes and nothing above it does, so the curve keeps
  /// exactly the part that trades.
  function test_refusingAboveTheFirstLevel_keepsOnlyThatLevel() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    _refuseAsksAtOrAbove(published.depth, 1);

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.asksExecutableLevels, 1, "only the shallowest level should survive");
  }

  /// The search lands on the exact boundary wherever it sits, and pays a logarithmic number of probes
  /// to find it rather than one per level.
  function test_findsTheBoundaryExactly_andSpendsLogProbes() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    uint256 levels = published.depth.asks.length;
    // Not `vm.assume`: setUp is deterministic, so a short ladder here means the
    // fixture changed and the test should say so rather than quietly pass.
    assertGe(levels, 4, "fixture should publish a ladder worth searching");

    uint256 boundary = levels / 2;
    _refuseAsksAtOrAbove(published.depth, boundary);

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.asksExecutableLevels, boundary, "prefix should end exactly at the refusal");
    assertLt(out.asksProbes, levels, "a linear scan would defeat the point");
  }

  /// The amount is the contract's primary answer, and it is a verified boundary rather than an
  /// interpolation: it is exactly the cumulative output of the deepest level that executed. A caller
  /// holding its own copy of the curve cuts at this number, which is why it must never be a guess.
  function test_executableAmountIsTheVerifiedBoundary() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    uint256 boundary = published.depth.asks.length / 2;
    _refuseAsksAtOrAbove(published.depth, boundary);

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.asksExecutableLevels, boundary);
    assertEq(
      out.asksExecutableAmountOut,
      out.depth.asks[boundary - 1].amountCumulative,
      "amount should be the last level that actually executed"
    );
    // The untouched side reports its deepest level, not a partial figure.
    assertEq(out.bidsExecutableAmountOut, out.depth.bids[out.depth.bids.length - 1].amountCumulative);
  }

  /// A closed side reports zero, not the shallowest level's amount. Publishing the latter would hand
  /// a caller a size the pool has just refused.
  function test_closedSideReportsZeroAmount() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    _refuseAsksAtOrAbove(published.depth, 0);

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertEq(out.asksExecutableLevels, 0);
    assertEq(out.asksExecutableAmountOut, 0, "a refused side must not report a tradeable size");
  }

  /// The pool clamps an exact-output request down to available liquidity instead of reverting
  /// (`_swapAcrossBins`), so a partial fill still comes back as `SimulateSwap` with non-zero deltas.
  /// That must count as a refusal: reporting it would publish a size the pool just declined to
  /// deliver, which is the whole failure this contract exists to prevent.
  function test_clampedPartialFillIsNotExecutable() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    uint256 deepest = published.depth.asks[published.depth.asks.length - 1].amountCumulative;

    // Answer the deepest probe with a well-formed SimulateSwap that delivers half what was asked.
    vm.mockCallRevert(
      address(pool),
      _probeCalldata(published.depth, deepest),
      abi.encodeWithSelector(
        IMetricOmmPoolActions.SimulateSwap.selector, -int256(deepest / 2), int256(published.depth.asks.length)
      )
    );

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertLt(out.asksExecutableLevels, out.depth.asks.length, "a clamped fill must not pass as executable");
    assertGt(out.asksProbes, 1, "the refusal should have sent the search into halving");
  }

  /// Deltas in the wrong direction are not a fill either — output must leave the pool and input enter.
  function test_wrongDirectionDeltasAreNotExecutable() public {
    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory published =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);
    uint256 deepest = published.depth.asks[published.depth.asks.length - 1].amountCumulative;

    vm.mockCallRevert(
      address(pool),
      _probeCalldata(published.depth, deepest),
      abi.encodeWithSelector(IMetricOmmPoolActions.SimulateSwap.selector, int256(deepest), int256(1))
    );

    MetricOmmPoolExecutableDepthProvider.ExecutableDepth memory out =
      lens.getExecutableLiquidityDepth(address(pool), WINDOW);

    assertLt(out.asksExecutableLevels, out.depth.asks.length);
  }

  // ============ Helpers ============

  /// @dev Make every ask level from `firstRefused` upward revert the way an extension would, by mocking
  ///      the exact probe calldata each of those levels generates. Levels below it keep answering for
  ///      real, so the boundary the search finds is a genuine one.
  function _refuseAsksAtOrAbove(MetricOmmPoolDataProvider.LiquidityDepth memory depth, uint256 firstRefused) internal {
    for (uint256 i = firstRefused; i < depth.asks.length; i++) {
      vm.mockCallRevert(address(pool), _probeCalldata(depth, depth.asks[i].amountCumulative), REFUSAL);
    }
  }

  /// @dev The ask-side probe the lens issues for a given target output: exact-out (negative
  ///      `amountSpecified`), `zeroForOne = false`, open upper price limit, prices from the snapshot.
  function _probeCalldata(MetricOmmPoolDataProvider.LiquidityDepth memory depth, uint256 amountOut)
    internal
    view
    returns (bytes memory)
  {
    return abi.encodeCall(
      IMetricOmmPoolActions.simulateSwapAndRevert,
      (
        address(lens),
        false,
        -int128(int256(amountOut)),
        type(uint128).max,
        depth.oracleBidX64,
        depth.oracleAskX64,
        depth.oracleReferenceX64,
        hex""
      )
    );
  }
}
