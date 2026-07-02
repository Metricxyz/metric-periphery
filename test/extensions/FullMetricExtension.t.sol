// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, MockPriceProvider} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {PoolExtensions} from "@metric-core/types/PoolExtensionsConfig.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {DepositAllowlistExtension} from "../../contracts/extensions/DepositAllowlistExtension.sol";
import {SwapAllowlistExtension} from "../../contracts/extensions/SwapAllowlistExtension.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {TestCaller} from "@metric-core-test/mocks/TestCaller.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract FullMetricExtensionTest is MetricOmmPoolBaseTest {
  MockPriceProvider priceProvider;
  DepositAllowlistExtension depositExtension;
  SwapAllowlistExtension swapExtension;

  uint72 constant EXTENSION_TEST_SALT = 777;

  function setUp() public override {
    factory = address(this);
    admin = address(this);
    adminFeeDestination = makeAddr("adminFeeDestination");

    delete users;
    delete callers;

    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);

    priceProvider = new MockPriceProvider();
    priceProvider.setBidAndAskPrice(SafeCast.toUint128(2 ** 64), SafeCast.toUint128(2 ** 64 + 1));
    oracle = priceProvider;

    depositExtension = new DepositAllowlistExtension(factory);
    swapExtension = new SwapAllowlistExtension(factory);

    pool = _deployPoolWithExtensions();

    _approveUsersForPool(address(pool));

    for (uint256 i = 0; i < 5; i++) {
      address user = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
      users.push(user);
      TestCaller caller = new TestCaller(user, factory);
      callers.push(caller);
      _setupUser(user, caller, address(pool));
    }
  }

  function test_blocksSwapWhenSwapperNotAllowed() public {
    depositExtension.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    _addLiquidity(0, -5, 4, 100_000, EXTENSION_TEST_SALT);

    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_blocksDepositWhenDepositorNotAllowed() public {
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _addLiquidity(0, -5, 4, 10_000, EXTENSION_TEST_SALT);
  }

  function test_allowedSwapSucceeds() public {
    depositExtension.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    swapExtension.setAllowedToSwap(address(pool), address(callers[0]), true);

    _addLiquidity(0, -5, 4, 100_000, EXTENSION_TEST_SALT);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function _deployPoolWithExtensions() internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();

    PoolExtensions memory extensions;
    extensions.extension1 = address(depositExtension);
    extensions.extension2 = address(swapExtension);

    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeAddLiquidity = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(2, 0, 0, 0, 0, 0, 0);

    return _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(priceProvider),
        extensions: extensions,
        extensionOrders: extensionOrders,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(priceProvider),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }
}
