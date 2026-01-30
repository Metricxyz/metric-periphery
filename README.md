# Metric Periphery

Periphery contracts for MetricOMM protocol - Router and Quoter contracts for swapping.

## Overview

This repository contains the periphery contracts that interact with MetricOMM core pools:

- **MetricOmmSwapRouter** - Router contract for executing swaps with support for native ETH
- **MetricOmmPoolQuoter** - Quoter contract for simulating swaps without execution

## Dependencies

This project depends on [metric-core](https://github.com/Metric-OMM/metric-core).

**Temporary setup:** Copy the `metric-core` repository into `lib/metric-core/`:

```bash
cp -r /path/to/metric-core lib/metric-core
```

> **Note:** Once metric-core is public, this will be converted to a proper git submodule.

## Setup

### Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Copy metric-core

```bash
# Copy from your local metric-core repo
cp -r ../metric-core lib/metric-core
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
