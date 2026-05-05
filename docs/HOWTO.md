# How to

## Build and test

From the repository root (with submodules initialized):

```bash
forge build
forge test
```

## Format Solidity

```bash
forge fmt
forge fmt --check
```

For non-Solidity files, follow project scripts in `package.json` if present (for example Prettier via Bun).

## Git hooks (optional)

This repository ships hooks under `.githooks/`. Enable them once per clone so commits run the same Solidity checks as CI:

```bash
git config --local core.hooksPath .githooks
```

The pre-commit hook runs `forge fmt --check` and then `forge test`. To skip it for a single commit:

```bash
git commit --no-verify
```

## Point an integration at the periphery

1. Deploy or reference **MetricOmmPoolRouter** with the canonical WETH address and the **MetricOmmPoolFactory** (or compatible factory implementing the same pool-resolution and immutables accessors the router expects).
2. For read-only bid/ask, depth, and quotes without execution, deploy **MetricOmmPoolSwapDataProvider** with the same factory address.
3. For liquidity adds with capped token pulls, deploy **MetricOmmPoolLiquidityAddition** and call through its documented interface after approving tokens to the contract as needed.

Exact constructor arguments and interface methods are defined on the Solidity interfaces under `contracts/interfaces/`.
