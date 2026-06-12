// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, MockPriceProvider} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {HookOrders} from "@metric-core/types/PoolHooksConfig.sol";
import {PoolHooks} from "@metric-core/types/PoolHooksConfig.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {HookOrderTestLib} from "@metric-core-test/HookOrderTestLib.sol";
import {DepositAllowlistHook} from "../../contracts/hooks/DepositAllowlistHook.sol";
import {SwapAllowlistHook} from "../../contracts/hooks/SwapAllowlistHook.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {TestCaller} from "@metric-core-test/mocks/TestCaller.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract FullMetricHookTest is MetricOmmPoolBaseTest {
  MockPriceProvider priceProvider;
  DepositAllowlistHook depositHook;
  SwapAllowlistHook swapHook;

  uint72 constant HOOK_TEST_SALT = 777;

  function setUp() public override {
    factory = address(this);
    admin = address(this);
    adminFeeDestination = makeAddr("adminFeeDestination");

    delete users;
    delete callers;

    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);

    priceProvider = new MockPriceProvider();
    priceProvider.setBidAndAskPrice(SafeCast.toUint128(2 ** 64), SafeCast.toUint128(2 ** 64));
    oracle = priceProvider;

    depositHook = new DepositAllowlistHook(factory);
    swapHook = new SwapAllowlistHook(factory);

    pool = _deployPoolWithHooks();

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
    depositHook.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    _addLiquidity(0, -5, 4, 100_000, HOOK_TEST_SALT);

    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_blocksDepositWhenDepositorNotAllowed() public {
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _addLiquidity(0, -5, 4, 10_000, HOOK_TEST_SALT);
  }

  function test_allowedSwapSucceeds() public {
    depositHook.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    swapHook.setAllowedToSwap(address(pool), address(callers[0]), true);

    _addLiquidity(0, -5, 4, 100_000, HOOK_TEST_SALT);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function _deployPoolWithHooks() internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();

    PoolHooks memory hooks;
    hooks.hook1 = address(depositHook);
    hooks.hook2 = address(swapHook);

    HookOrders memory hookOrders;
    hookOrders.beforeAddLiquidity = HookOrderTestLib.encodeHookOrder(1, 0, 0, 0, 0, 0, 0);
    hookOrders.beforeSwap = HookOrderTestLib.encodeHookOrder(2, 0, 0, 0, 0, 0, 0);

    return _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(priceProvider),
        hooks: hooks,
        hookOrders: hookOrders,
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
