// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, MockPriceProvider} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IPriceProviderSwapReporter} from "@metric-core/interfaces/IPriceProvider/IPriceProviderSwapReporter.sol";
import {FullMetricHook} from "../../contracts/hooks/examples/FullMetricHook.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {TestCaller} from "@metric-core-test/mocks/TestCaller.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockPriceProviderWithSwapReport is MockPriceProvider, IPriceProviderSwapReporter {
  uint256 public reportCount;

  function reportSwap(address, address, bool, int128, uint128, int256, int256, int8, uint104) external {
    reportCount++;
  }
}

contract FullMetricHookTest is MetricOmmPoolBaseTest {
  MockPriceProviderWithSwapReport priceProviderWithReport;
  FullMetricHook hook;

  uint72 constant HOOK_TEST_SALT = 777;

  function setUp() public override {
    factory = address(this);
    admin = address(this);
    adminFeeDestination = makeAddr("adminFeeDestination");

    delete users;
    delete callers;

    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);

    priceProviderWithReport = new MockPriceProviderWithSwapReport();
    priceProviderWithReport.setBidAndAskPrice(SafeCast.toUint128(2 ** 64), SafeCast.toUint128(2 ** 64));
    oracle = priceProviderWithReport;

    uint256 deployNonce = vm.getNonce(address(this));
    address predictedPool = vm.computeCreateAddress(address(this), deployNonce + 1);

    hook = new FullMetricHook(predictedPool, factory);

    pool = _deployPoolWithHook(address(hook), hook.getHookPermissions());
    assertEq(address(pool), predictedPool);

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
    hook.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    _addLiquidity(0, -5, 4, 100_000, HOOK_TEST_SALT);

    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_blocksDepositWhenDepositorNotAllowed() public {
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _addLiquidity(0, -5, 4, 10_000, HOOK_TEST_SALT);
  }

  function test_swapReportsAfterAllowedSwap() public {
    hook.setAllowedToDeposit(address(pool), _getCallerAddress(0), true);
    hook.setAllowedToSwap(address(pool), address(callers[0]), true);

    _addLiquidity(0, -5, 4, 100_000, HOOK_TEST_SALT);

    assertEq(priceProviderWithReport.reportCount(), 0);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
    assertEq(priceProviderWithReport.reportCount(), 1);
  }

  function _deployPoolWithHook(address hooks, uint16 hooksPermissions) internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    return _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(priceProviderWithReport),
        hooks: hooks,
        hooksPermissions: hooksPermissions,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(priceProviderWithReport),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }
}
