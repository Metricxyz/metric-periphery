// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {LiquidityLadder} from "../contracts/libraries/LiquidityLadder.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {CapExtension} from "./mocks/extensions/CapExtension.sol";

/// @title MetricOmmPoolDataProvider depth ladder binary-search fallback
/// @notice Proves the ladder builder binary-searches around a size-dependent extension revert instead of
///         aborting: a `beforeSwap` cap blocks any trade past a threshold inside the current bin, so the
///         ladder must stop at exactly that threshold rather than at the bin's full capacity.
contract MetricOmmPoolDataProviderDepthCapExtensionTest is SimpleRouterTestBase {
  MetricOmmPoolDataProvider internal dataProvider;
  CapExtension internal capExtension;
  MetricOmmPool internal cappedPool;

  function setUp() public override {
    super.setUp();
    dataProvider = new MetricOmmPoolDataProvider(address(factoryStub));
    capExtension = new CapExtension();
    cappedPool = _deployCappedPool();
    _seedLiquidityPool(cappedPool, address(weth), address(token1), 2);
  }

  function test_getLiquidityDepthLive_stopsAtBinarySearchedCapWhenExtensionBlocksFurtherAsks() public {
    LiquidityLadder.LiquidityDepth memory uncapped = dataProvider.getLiquidityDepthLive(address(cappedPool), 4);
    assertGt(uncapped.asks.length, 0, "expected at least one ask row before capping");
    uint256 fullAskRoom = uncapped.asks[0].amountAvailableInBin;

    uint256 cap = fullAskRoom / 3;
    assertGt(cap, 0, "cap must be nonzero to be meaningful");
    capExtension.setCap(cap);

    LiquidityLadder.LiquidityDepth memory depth = dataProvider.getLiquidityDepthLive(address(cappedPool), 4);

    assertEq(depth.asks.length, 1, "ladder should stop at the capped bin instead of continuing past it");
    // 20 bisection probes over an initial [0, fullAskRoom] range converge to within fullAskRoom / 2**20 of the
    // true cap; bisection only ever keeps amounts that actually succeeded, so it can undershoot but never overshoot.
    assertLe(depth.asks[0].cumulativeOut, cap, "binary search must not overshoot the cap");
    assertGe(
      depth.asks[0].cumulativeOut,
      cap - fullAskRoom / (2 ** 20) - 1,
      "binary search should converge close to the cap within 20 iterations"
    );
  }

  function _deployCappedPool() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    extensions.extension1 = address(capExtension);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    deployed = new MetricOmmPool(
      address(factoryStub),
      address(weth),
      address(token1),
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_OPERATIONAL_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0,
      type(uint16).max
    );

    factoryStub.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("cappedAdminFeeDest"),
      address(this)
    );
  }
}
