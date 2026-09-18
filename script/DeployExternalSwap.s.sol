// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {ExternalSwapExecutor} from "../contracts/base/ExternalSwapExecutor.sol";

/// @title DeployExternalSwap
/// @notice Deploys `MetricOmmSimpleRouter` (with `externalSwap` + `sequence`) and its
///         `ExternalSwapExecutor`, on Ethereum mainnet, via CREATE2.
///
/// @dev CREATE2 is not optional here. Every existing protocol address is identical on all
///      ten supported chains (the SDK spreads one `PROTOCOL_ADDRESSES` object across them),
///      and `foundry.toml` sets `bytecode_hash = "none"` so initcode is reproducible across
///      machines. A plain `CREATE` deployment would be nonce-dependent and would break that
///      invariant the moment a second chain is added.
///
///      `new C{salt: s}(...)` inside a broadcast is routed by Foundry through the canonical
///      deterministic-deployment proxy at `0x4e59b448...`, which is what makes the address a
///      pure function of (initcode, salt) — verify it before you broadcast.
///
/// @dev The script is **idempotent**: if the predicted address already holds code it adopts it
///      instead of redeploying (CREATE2 would revert anyway). Re-running after a partial
///      failure resumes rather than starts over.
///
/// Runbook
/// -------
///   export ROUTER_SALT=0x...      # 32 bytes, required
///   export EXECUTOR_SALT=0x...    # 32 bytes, required
///   # optional: reuse an already-deployed router instead of deploying one
///   export ROUTER_ADDRESS=0x...
///
///   # 1. Simulate. Prints both predicted addresses and broadcasts NOTHING.
///   forge script script/DeployExternalSwap.s.sol:DeployExternalSwap --rpc-url "$ETH_RPC_URL"
///
///   # 2. Rehearse against a mainnet fork (anvil --fork-url "$ETH_RPC_URL" keeps chainid 1,
///   #    so the mainnet guard below still passes).
///
///   # 3. Broadcast, only once the predicted addresses match what you expect.
///   forge script script/DeployExternalSwap.s.sol:DeployExternalSwap \
///     --rpc-url "$ETH_RPC_URL" --broadcast --verify --etherscan-api-key "$ETHERSCAN_API_KEY" \
///     --ledger   # or --private-key / --keystore; never inline a raw key
///
/// After broadcasting, add both addresses to the SDK's `PROTOCOL_ADDRESSES`.
contract DeployExternalSwap is Script {
  /// @dev The only chain this script will run against. Mainnet-only is deliberate; a fork of
  ///      mainnet reports chainid 1 too, so rehearsal still works.
  uint256 internal constant MAINNET_CHAIN_ID = 1;

  // `CREATE2_FACTORY` (the canonical deterministic-deployment proxy at 0x4e59b448...) is
  // inherited from forge-std's `Base`. Foundry routes salted `new` through it, which is what
  // makes the deployed address a pure function of (initcode, salt).

  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  /// @dev `MetricOmmPoolFactory`, from the SDK's `PROTOCOL_ADDRESSES`. Identical on every chain.
  address internal constant POOL_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;

  function run() external {
    require(block.chainid == MAINNET_CHAIN_ID, "DeployExternalSwap: mainnet only");
    require(CREATE2_FACTORY.code.length > 0, "DeployExternalSwap: CREATE2 factory missing");
    require(WETH.code.length > 0, "DeployExternalSwap: WETH has no code");
    require(POOL_FACTORY.code.length > 0, "DeployExternalSwap: pool factory has no code");

    bytes32 routerSalt = vm.envBytes32("ROUTER_SALT");
    bytes32 executorSalt = vm.envBytes32("EXECUTOR_SALT");

    address router = _resolveRouter(routerSalt);
    address executor = _resolveExecutor(executorSalt, router);

    // The invariant that makes the pair usable: the executor only accepts calls from this
    // router, and the router funds this executor. A mismatch is silently unusable on-chain.
    require(ExternalSwapExecutor(executor).router() == router, "DeployExternalSwap: router mismatch");

    console2.log("");
    console2.log("=== deployed ===");
    console2.log("MetricOmmSimpleRouter :", router);
    console2.log("ExternalSwapExecutor  :", executor);
    console2.log("");
    console2.log("Verify constructor args (for --verify / Etherscan):");
    console2.log("  router  : %s", vm.toString(abi.encode(WETH, POOL_FACTORY)));
    console2.log("  executor: %s", vm.toString(abi.encode(router)));
  }

  /// @dev Deploy the router, unless `ROUTER_ADDRESS` names one or the predicted address is
  ///      already occupied.
  function _resolveRouter(bytes32 salt) internal returns (address) {
    address preset = vm.envOr("ROUTER_ADDRESS", address(0));
    if (preset != address(0)) {
      require(preset.code.length > 0, "DeployExternalSwap: ROUTER_ADDRESS has no code");
      console2.log("router     : reusing ROUTER_ADDRESS", preset);
      return preset;
    }

    bytes memory initCode = abi.encodePacked(type(MetricOmmSimpleRouter).creationCode, abi.encode(WETH, POOL_FACTORY));
    address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
    console2.log("router     : predicted", predicted);

    if (predicted.code.length > 0) {
      console2.log("router     : already deployed, adopting");
      return predicted;
    }

    vm.startBroadcast();
    MetricOmmSimpleRouter deployed = new MetricOmmSimpleRouter{salt: salt}(WETH, POOL_FACTORY);
    vm.stopBroadcast();

    require(address(deployed) == predicted, "DeployExternalSwap: router address drift");
    return predicted;
  }

  /// @dev Deploy the executor bound to `router`. Its address depends on `router`, so changing
  ///      the router necessarily changes the executor address even at the same salt.
  function _resolveExecutor(bytes32 salt, address router) internal returns (address) {
    bytes memory initCode = abi.encodePacked(type(ExternalSwapExecutor).creationCode, abi.encode(router));
    address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
    console2.log("executor   : predicted", predicted);

    if (predicted.code.length > 0) {
      console2.log("executor   : already deployed, adopting");
      return predicted;
    }

    vm.startBroadcast();
    ExternalSwapExecutor deployed = new ExternalSwapExecutor{salt: salt}(router);
    vm.stopBroadcast();

    require(address(deployed) == predicted, "DeployExternalSwap: executor address drift");
    return predicted;
  }
}
