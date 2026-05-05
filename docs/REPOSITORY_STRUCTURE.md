# Repository structure

```text
.
├── contracts/                 # Periphery Solidity sources
│   ├── MetricOmmPoolRouter.sol
│   ├── MetricOmmPoolLiquidityAddition.sol
│   ├── MetricOmmPoolSwapDataProvider.sol
│   ├── interfaces/          # External ABIs / documentation surface
│   ├── common/              # Shared MetricOmmPoolQuoter (inherited by router and swap data provider)
│   └── mocks/               # Test doubles shipped with the repo (e.g. MockWETH9)
├── test/forge/              # Foundry tests
├── lib/                     # Git submodules (metric-core, forge-std, etc.)
├── .githooks/               # Optional Git hooks (enable with core.hooksPath)
├── docs/                    # Technical notes (this tree, architecture, how-to)
└── README.md                # Entry-point overview
```

Scripts, CI, and tooling configuration may live at the repository root; prefer `exec/` for operational entrypoints and `scripts/` for small helpers when those directories exist.
