# Metric Periphery

Periphery contracts for the MetricOMM protocol: pool swaps, read-only swap and depth data, and liquidity adds with caller-funded settlement.

## Overview

Main Solidity contracts (implementation):

- **MetricOmmPoolSwapper** — Executes swaps against pools, including native ETH paths, and inherits **MetricOmmPoolQuoter** for `quoteSwap`-style simulation on the same code path.
- **MetricOmmPoolSwapDataProvider** — Read-only contract combining best bid/ask, liquidity depth ladders, and quoter behavior; extends the shared **MetricOmmPoolQuoter** base from `contracts/common/`.
- **MetricOmmPoolLiquidityAdder** — Adds liquidity on behalf of callers with max-token caps and weighted or exact-share flows.

Shared **MetricOmmPoolQuoter** is in `contracts/common/MetricOmmPoolQuoter.sol` and is extended by both the swapper and the swap data provider.

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

If `.gitmodules` was updated (e.g. org rename), run `git submodule sync --recursive` once so local remotes match.

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

- **Solidity**: Foundry only.

```bash
forge fmt --check
forge fmt
```

- **Markdown / JSON / YAML** (optional): after `npm install`, run `npm run format:prettier` or `npm run format:prettier:check`. Solidity is listed in `.prettierignore` — use **`forge fmt`** for `.sol` files, not Prettier.

CI runs Prettier check, `forge fmt --check`, build, and tests (see `.github/workflows/test.yml`). Workflows pin **Foundry 1.7.0** and **`solc` 0.8.35** — match locally (`forge --version`, same `foundry.toml` `solc`).

Optional local pre-commit checks live in `.githooks/` (same pattern as **metric-core**): enable with `git config --local core.hooksPath .githooks`. The hook runs `npm run format:prettier:check`, `forge fmt --check`, and `forge test` (run `npm install` once). Use `git commit --no-verify` to skip.

## Project structure

```text
contracts/
├── MetricOmmPoolSwapper.sol
├── MetricOmmPoolLiquidityAdder.sol
├── MetricOmmPoolSwapDataProvider.sol
├── interfaces/          # IMetricOmmPoolSwapper, IMetricOmmPoolQuoter, IMetricOmmPoolSwapDataProvider, IMetricOmmPoolLiquidityAdder, IWETH9
├── common/
│   └── MetricOmmPoolQuoter.sol       # Shared quoter; inherited by swapper and swap data provider

test/                    # Foundry tests (*.t.sol) and shared helpers (RouterTestFactory, SwapDataHelperTestBase, …)
test/mocks/              # MockWETH9 and other test-only doubles
```

## License

UNLICENSED
