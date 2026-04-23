# Metric Periphery

Periphery contracts for MetricOMM protocol - Router and Quoter contracts for swapping.

## Overview

This repository contains the periphery contracts that interact with MetricOMM core pools:

- **MetricOmmSwapRouter** - Router contract for executing swaps with support for native ETH
- **MetricOmmPoolQuoter** - Quoter contract for simulating swaps without execution

## Dependencies

This project depends on:

- [metric-core](https://github.com/Metric-OMM/metric-core)
- [forge-std](https://github.com/foundry-rs/forge-std)
- [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [sstore2](https://github.com/0xsequence/sstore2)

All dependencies are configured as git submodules under `lib/`.

> **Note:** `metric-core` is private. Ensure your GitHub credentials (SSH key or token) have access.

### CI (GitHub Actions)

CI checks out this repository with the default `GITHUB_TOKEN`, then clones submodules in a separate step. That token cannot read other private repos, so add a **repository secret** `PRIVATE_SUBMODULES_PAT`: a [personal access token](https://github.com/settings/tokens) with **read access to `Metric-OMM/metric-core` only** (fine-grained is enough). The workflow rewrites only `https://github.com/Metric-OMM/…` URLs to use that PAT, so it must **not** be passed as the `actions/checkout` `token` input (that would authenticate the main fetch and a core-only PAT yields 403 on `metric-periphery`). Without the secret, submodule init fails (often “repository not found” for `metric-core`).

## Setup

### Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Initialize submodules

```bash
# after clone
git submodule update --init --recursive
```

Or clone with submodules in one step:

```bash
git clone --recurse-submodules https://github.com/Metric-OMM/metric-periphery.git
```

## Build

```bash
forge build
```

## Test

```bash
forge test
```

With verbosity:

```bash
forge test -vvv
```

## Formatting

```bash
# Check formatting
forge fmt --check

# Fix formatting
forge fmt
```

CI pins the Foundry release in `.github/workflows/test.yml` so `forge fmt --check` and `forge test` match what runs on GitHub. Use the same Forge version locally as in that workflow (`forge --version`).

## Project Structure

```
contracts/
├── MetricOmmSwapRouter.sol    # Main router for swaps
├── MetricOmmPoolQuoter.sol    # Quoter for swap simulation
├── ChunkDeployer.sol          # Large contract deployment helper
├── interfaces/
│   ├── IWETH9.sol             # WETH interface
│   └── callbacks/
│       └── IMetricOmmSwapCallback.sol
├── libraries/
│   └── WrappedERC20.sol       # Safe ERC20 operations
└── mocks/
    └── MockWETH9.sol          # WETH mock for testing
```

## License

UNLICENSED
