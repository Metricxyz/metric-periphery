// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {PoolInitPreprocessor} from "../../lib/metric-core/test/PoolInitPreprocessor.sol";
import {MetricOmmSimpleRouter} from "../../contracts/MetricOmmSimpleRouter.sol";
import {MetricOmmSwapQuoter} from "../../contracts/lens/MetricOmmSwapQuoter.sol";
import {MockWETH9} from "../mocks/MockWETH9.sol";
import {RouterTestFactory} from "../RouterTestFactory.sol";
import {LiquidityHelper} from "./LiquidityHelper.sol";

contract MockPriceProviderRouter is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;
  address public baseToken;
  address public quoteToken;

  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  function setTokens(address _baseToken, address _quoteToken) external {
    baseToken = _baseToken;
    quoteToken = _quoteToken;
  }

  function getBidAndAskPrice() external returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external view returns (address) {
    return baseToken;
  }

  function token1() external view returns (address) {
    return quoteToken;
  }

  function getBidPrice() external view returns (uint256) {
    return bidPrice;
  }

  function getBidPriceUi() external view returns (uint256) {
    return bidPrice;
  }

  function getAskPrice() external view returns (uint256) {
    return askPrice;
  }

  function getAskPriceUi() external view returns (uint256) {
    return askPrice;
  }

  function getBidAndAskPriceUi() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function setConfidenceParam(uint256) external {}
  function setCexStep(int256) external {}
  function setClOracle(address, address, uint32) external {}
  function removeClOracle(address) external {}
  function setMaxClDeviation(uint16) external {}
}

abstract contract SimpleRouterTestBase is Test, PoolInitPreprocessor {
  uint256 internal constant Q64 = 2 ** 64;
  uint128 internal constant TEST_BID_X64 = uint128(Q64);
  uint128 internal constant TEST_ASK_X64 = uint128(Q64 + 1);
  uint128 internal constant MAX_INT128_AS_UINT128 = uint128(type(int128).max);

  MetricOmmSimpleRouter internal router;
  MetricOmmSwapQuoter internal quoter;
  RouterTestFactory internal factoryStub;
  MockWETH9 internal weth;
  MockERC20 internal token1;
  MockERC20 internal token2;
  MockPriceProviderRouter internal oracle;
  LiquidityHelper internal lpContract;

  MetricOmmPool internal pool;
  MetricOmmPool internal pool12;

  address internal lp;
  address internal swapper;
  address internal recipient;
  uint256 internal swapperPrivateKey;

  uint104 internal constant INITIAL_TOKEN_0_DENSITY = 1e18;
  uint104 internal constant INITIAL_TOKEN_1_DENSITY = 1e18;
  uint104 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  uint24 internal constant PROTOCOL_FEE = 1e4;
  uint24 internal constant ADMIN_FEE = 5e3;

  function setUp() public virtual {
    (swapper, swapperPrivateKey) = makeAddrAndKey("swapper");
    lp = makeAddr("lp");
    recipient = makeAddr("recipient");

    factoryStub = new RouterTestFactory();
    weth = new MockWETH9();
    token1 = new MockERC20("Token1", "TK1", 18);
    token2 = new MockERC20("Token2", "TK2", 18);

    oracle = new MockPriceProviderRouter();
    oracle.setTokens(address(weth), address(token1));
    oracle.setBidAndAskPrice(TEST_BID_X64, TEST_ASK_X64);

    router = new MetricOmmSimpleRouter(address(weth), address(factoryStub));
    quoter = new MetricOmmSwapQuoter();
    lpContract = new LiquidityHelper();

    pool = _deployPool(address(weth), address(token1));
    pool12 = _deployPool(address(token1), address(token2));

    _seedLiquidityPool(pool, address(weth), address(token1), 0);
    _seedLiquidityPool(pool12, address(token1), address(token2), 1);

    vm.deal(swapper, 100 ether);
    token1.mint(swapper, 1_000_000e18);
    token2.mint(swapper, 1_000_000e18);
    vm.startPrank(swapper);
    weth.deposit{value: 20 ether}();
    weth.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);
    token2.approve(address(router), type(uint256).max);
    vm.stopPrank();
  }

  function _deployPool(address token0Addr, address token1Addr) internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) = _getScaleMultipliers(token0Addr, token1Addr);

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;

    deployed = new MetricOmmPool(
      address(factoryStub),
      address(this),
      makeAddr("adminFeeDest"),
      token0Addr,
      token1Addr,
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0
    );

    factoryStub.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("adminFeeDest"),
      address(this)
    );
  }

  function _seedLiquidityPool(MetricOmmPool target, address token0Addr, address token1Addr, uint80 salt) internal {
    vm.deal(lp, 100 ether);
    vm.startPrank(lp);
    if (token0Addr == address(weth)) {
      weth.deposit{value: 10 ether}();
    } else {
      MockERC20(token0Addr).mint(lp, 1_000_000e18);
    }
    MockERC20(token1Addr).mint(lp, 1_000_000e18);
    if (token0Addr == address(weth)) {
      // forge-lint: disable-next-line(erc20-unchecked-transfer)
      weth.transfer(address(lpContract), 5 ether);
    } else {
      // forge-lint: disable-next-line(erc20-unchecked-transfer)
      MockERC20(token0Addr).transfer(address(lpContract), 500_000e18);
    }
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    MockERC20(token1Addr).transfer(address(lpContract), 500_000e18);
    vm.stopPrank();

    vm.startPrank(address(lpContract));
    if (token0Addr == address(weth)) {
      weth.approve(address(target), type(uint256).max);
    } else {
      MockERC20(token0Addr).approve(address(target), type(uint256).max);
    }
    MockERC20(token1Addr).approve(address(target), type(uint256).max);
    vm.stopPrank();

    lpContract.addLiquidityRange(address(target), salt, -4, 4, 100_000);
  }

  function _deadline() internal pure returns (uint256) {
    return type(uint256).max;
  }

  function _priceLimit(bool zeroForOne) internal pure returns (uint128) {
    return zeroForOne ? 0 : type(uint128).max;
  }

  function _binPackedArrays() internal pure returns (uint256[] memory nn, uint256[] memory neg) {
    nn = new uint256[](1);
    neg = new uint256[](1);
    uint256 packed;
    uint16 lengthE6 = 100;
    for (uint256 j; j < 5; j++) {
      uint48 binData = uint48(lengthE6) | (uint48(0) << 16) | (uint48(0) << 32);
      packed |= uint256(binData) << (j * 48);
    }
    nn[0] = packed;
    neg[0] = packed;
  }

  function _assertRouterEmpty() internal view {
    assertEq(address(router).balance, 0, "router eth");
    assertEq(weth.balanceOf(address(router)), 0, "router weth");
    assertEq(token1.balanceOf(address(router)), 0, "router token1");
    assertEq(token2.balanceOf(address(router)), 0, "router token2");
  }
}
