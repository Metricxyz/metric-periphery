// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {MetricOmmPoolDataProvider} from "../contracts/lens/MetricOmmPoolDataProvider.sol";
import {LiquidityLadder} from "../contracts/libraries/LiquidityLadder.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

/// @title MetricOmmPoolDataProvider depth ladder with non-uniform bin widths
/// @notice Regression test for a bug where `_buildBidLadder` subtracted the wrong bin's `lengthE6` when
///         walking downward, which uniform-width test pools could never catch (the wrong-bin substitution
///         happens to cancel out when every bin has the same length). Adjacent bins are geometrically
///         contiguous, so a correct walk must report each row's `upperEffPriceX64` exactly equal to the
///         row above it's `lowerEffPriceX64`; this pool gives every bin on both sides a distinct length so
///         that invariant only holds if the walk arithmetic is actually correct.
contract MetricOmmPoolDataProviderDepthNonUniformBinsTest is SimpleRouterTestBase {
  MetricOmmPoolDataProvider internal dataProvider;
  MetricOmmPool internal varyingPool;

  function setUp() public override {
    super.setUp();
    dataProvider = new MetricOmmPoolDataProvider(address(factoryStub));
    varyingPool = _deployPoolWithVaryingBinLengths();
    _seedLiquidityPool(varyingPool, address(weth), address(token1), 2);
  }

  function test_getLiquidityDepthLive_bidRowsStayContiguousAcrossVaryingBinWidths() public {
    LiquidityLadder.LiquidityDepth memory depth = dataProvider.getLiquidityDepthLive(address(varyingPool), 4);

    assertGt(depth.bids.length, 1, "expected multiple bid rows to check contiguity");
    for (uint256 i = 1; i < depth.bids.length; i++) {
      assertEq(
        depth.bids[i].upperEffPriceX64,
        depth.bids[i - 1].lowerEffPriceX64,
        "bid row upper bound must equal the row above it's lower bound"
      );
    }

    assertGt(depth.asks.length, 1, "expected multiple ask rows to check contiguity");
    for (uint256 i = 1; i < depth.asks.length; i++) {
      assertEq(
        depth.asks[i - 1].upperEffPriceX64,
        depth.asks[i].lowerEffPriceX64,
        "ask row upper bound must equal the row below it's lower bound"
      );
    }
  }

  function _deployPoolWithVaryingBinLengths() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _varyingBinPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;

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
      makeAddr("varyingAdminFeeDest"),
      address(this)
    );
  }

  /// @dev Non-negative bins 0..4 and negative bins -1..-4 each get a distinct `lengthE6`, zero add-fees.
  function _varyingBinPackedArrays() internal pure returns (uint256[] memory nn, uint256[] memory neg) {
    uint16[5] memory nonNegativeLengths = [uint16(100), 120, 140, 160, 180];
    uint16[5] memory negativeLengths = [uint16(90), 130, 170, 210, 0];

    nn = new uint256[](1);
    neg = new uint256[](1);
    uint256 nnPacked;
    uint256 negPacked;
    for (uint256 j; j < 5; j++) {
      nnPacked |= uint256(uint48(nonNegativeLengths[j])) << (j * 48);
      negPacked |= uint256(uint48(negativeLengths[j])) << (j * 48);
    }
    nn[0] = nnPacked;
    neg[0] = negPacked;
  }
}
