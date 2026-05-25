# psi-contracts

PSI Finance staking vault contracts — a fork of [robin-markets/staking-vault-contracts](https://github.com/robin-markets/staking-vault-contracts) rebranded for deployment on Polygon mainnet.

## Status

Phase 0 + Phase 1 of [`implementation.md`](./implementation.md) complete:

- Forked from upstream commit `2d4d1a3`.
- 5 contracts + 10 interfaces renamed `Robin*` → `Psi*` (history preserved via `git mv`).
- EIP-712 domain set to `PsiStakingVault`.
- Metadata URI set to `https://api.psi.finance/v1/shares/{id}`.
- ERC-7201 storage namespaces intentionally kept as `robin.storage.*` (internal-only, see `docs/FORK_CHANGES.md`).
- `forge build` passes — 85 files compile clean on Solc 0.8.31.

See [`docs/FORK_CHANGES.md`](./docs/FORK_CHANGES.md) for the full rename map, license preservation notes, and decisions taken.

## Build

```bash
forge build
```

Requires Foundry (Solidity 0.8.31).

## License

This fork preserves upstream licensing:

- `licenses/BSL_LICENSE` (Business Source License 1.1)
- `licenses/MIT_LICENSE`

Per-file SPDX headers indicate which license applies to each source file.

## Upstream attribution

- Source repo: https://github.com/robin-markets/staking-vault-contracts
- Forked at commit: `2d4d1a3d8dfd10030c5407a70247fe16d766f98f`
- Upstream audit (preserved in `audits/`): Phage Security, Feb 2026
