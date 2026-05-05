# Conventions

## Solidity

- Contracts use Solidity `^0.8.33` as pinned in Foundry configuration.
- Format with `forge fmt`; keep NatSpec on public interfaces where behavior is non-obvious.
- Periphery naming uses the **MetricOmmPool** prefix for router, liquidity addition, quoter, and swap data types to align with pool-centric deployment.

## Repository

- Core dependency lives in `lib/metric-core` as a submodule.
- Interfaces for this repo live in `contracts/interfaces/`; the shared quoter used by the router and swap data provider lives in `contracts/common/MetricOmmPoolQuoter.sol`.

## Commits

Follow the commit message structure described in `.cursor/rules/commit-message-format.mdc` when preparing changes for review.

Optionally point Git at `.githooks` (see `docs/HOWTO.md`) so pre-commit runs `forge fmt --check` and `forge test` before each local commit.
