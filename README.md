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

## Format

```bash
forge fmt
```

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
