# PSI Finance — Fork Changes

## Upstream

- **Repo:** https://github.com/robin-markets/staking-vault-contracts
- **Branch:** `main`
- **Commit:** `2d4d1a3d8dfd10030c5407a70247fe16d766f98f`
- **Commit subject:** "add missing submodule gitlinks for lib dependencies"
- **Forked at:** 2026-05-25T12:03Z

## Licenses (preserved unchanged)

- `licenses/BSL_LICENSE` — Business Source License 1.1
- `licenses/MIT_LICENSE` — MIT License
- SPDX headers in all source files (`SPDX-License-Identifier: BSL-1.1` or `MIT`) preserved verbatim.
- `audits/RobinMarkets-PhageSecurity-Feb2026.pdf` preserved as upstream attribution.
- `broadcast/DeployRobinStakingVault.s.sol/137/run-1776211857782.json` preserved as historical reference (useful for confirming Robin's deployed collateral choices).

## Scope of this fork pass (Phase 0 + Phase 1 only)

Phase 0 — Baseline build verified on unmodified upstream:
- `forge build` → `Compiler run successful!` (85 files, Solc 0.8.31)
- `forge test` → no tests in upstream repo (`test/` directory does not exist)

Phase 1 — Mechanical rebrand Robin → Psi.

Phases 2–9 (deploy script, tests, env, ABI export, backend, frontend, security, runbook) are **not** part of this pass.

## Contract file renames (5)

| Upstream | Fork |
|---|---|
| `src/RobinLens.sol` | `src/PsiLens.sol` |
| `src/RobinStakingVault.sol` | `src/PsiStakingVault.sol` |
| `src/RobinStakingVaultExtension.sol` | `src/PsiStakingVaultExtension.sol` |
| `src/RobinTimeLockController.sol` | `src/PsiTimeLockController.sol` |
| `src/RobinTwapOracle.sol` | `src/PsiTwapOracle.sol` |

## Interface file renames (10)

All under `src/interfaces/`:

| Upstream | Fork |
|---|---|
| `IRobinAccountingView.sol` | `IPsiAccountingView.sol` |
| `IRobinLens.sol` | `IPsiLens.sol` |
| `IRobinPausableView.sol` | `IPsiPausableView.sol` |
| `IRobinPolymarketView.sol` | `IPsiPolymarketView.sol` |
| `IRobinSignaturesView.sol` | `IPsiSignaturesView.sol` |
| `IRobinStakingVault.sol` | `IPsiStakingVault.sol` |
| `IRobinStakingVaultErrors.sol` | `IPsiStakingVaultErrors.sol` |
| `IRobinStakingVaultEvents.sol` | `IPsiStakingVaultEvents.sol` |
| `IRobinTwapOracle.sol` | `IPsiTwapOracle.sol` |
| `IRobinYieldStrategyView.sol` | `IPsiYieldStrategyView.sol` |

All renames done via `git mv` so file history is preserved.

## Identifier renames

Case-sensitive `Robin → Psi` applied across all `*.sol` files in `src/`. This updates:

- Contract class names (`contract RobinStakingVault` → `contract PsiStakingVault`, etc.)
- Interface names (`IRobin*` → `IPsi*`)
- Import paths (`import { IRobinX } from "./interfaces/IRobinX.sol"` → `import { IPsiX } from "./interfaces/IPsiX.sol"`)
- Doc comments (`/// @title RobinX`, `/// @notice ... Robin vault ...`)
- The one hardcoded EIP-712 domain name in source (see below).

## EIP-712 domain name change

Only one EIP-712 domain string was hardcoded in source code:

```solidity
// src/PsiStakingVault.sol:72
__SignaturesMixin_init('PsiStakingVault', '1', params.ctfExchange);
```

(was `'RobinStakingVault'` upstream)

Note: `PsiTwapOracle.initialize(...)` accepts `name` and `version` as parameters, so its EIP-712 domain is set by the deployer, not in source. The deploy script (Phase 3, not in this pass) must pass `"PsiTwapOracle"` and `"1"`.

## Metadata URI

Default ERC-1155 metadata URI changed:

```
- 'https://api.robin.markets/v1/shares/{id}'
+ 'https://api.psi.finance/v1/shares/{id}'
```

Location: `src/PsiStakingVault.sol:67`.

> Pending for Phase 2: make this env-driven (`PSI_METADATA_URI`) so dev/staging/prod can point at different APIs without redeploy. Currently hardcoded to production URL.

## Storage namespaces — INTENTIONALLY NOT RENAMED

ERC-7201 storage namespace strings kept as `robin.storage.*` upstream values:

| File | Namespace |
|---|---|
| `src/PsiTwapOracle.sol` | `robin.storage.TwapOracle` |
| `src/libraries/StorageLib.sol` | `robin.storage.Accounting` |
| `src/libraries/StorageLib.sol` | `robin.storage.YieldStrategy` |
| `src/libraries/StorageLib.sol` | `robin.storage.Polymarket` |
| `src/libraries/StorageLib.sol` | `robin.storage.Pausable` |
| `src/libraries/StorageLib.sol` | `robin.storage.Signatures` |
| `src/libraries/StorageLib.sol` | `robin.storage.Extension` |

**Rationale:** These strings are internal-only — they feed `keccak256` to compute the storage slot constant, never appear in any external interface, ABI, event, or user-visible string. Renaming them to `psi.storage.*` would change every contract's storage layout. For a fresh PSI deployment that has no shared state with Robin, the namespace value is meaningless — only consistency within the PSI contract suite matters, and that is preserved.

## Files left untouched

- `foundry.toml` (Solidity 0.8.31, optimizer enabled with `optimizer_runs = 1`, no Robin-specific strings)
- `remappings.txt`
- `lib/` (submodules: forge-std, openzeppelin-contracts-upgradeable, openzeppelin-foundry-upgrades)
- `licenses/`, `audits/`, `broadcast/` (attribution / historical)
- `.gitignore`, `.gitmodules`

## Verification

```
$ forge build
Compiling 85 files with Solc 0.8.31
Compiler run successful!

$ grep -rn "Robin" src
(no matches — exit 1)

$ grep -rn "robin" src
src/PsiTwapOracle.sol:44:    /// @custom:storage-location erc7201:robin.storage.TwapOracle
src/PsiTwapOracle.sol:56:    /// @dev keccak256(abi.encode(uint256(keccak256("robin.storage.TwapOracle")) - 1)) & ~bytes32(uint256(0xff))
src/libraries/StorageLib.sol:17:    /// @custom:storage-location erc7201:robin.storage.Accounting
src/libraries/StorageLib.sol:46:    /// @custom:storage-location erc7201:robin.storage.YieldStrategy
src/libraries/StorageLib.sol:68:    /// @custom:storage-location erc7201:robin.storage.Polymarket
src/libraries/StorageLib.sol:92:    /// @custom:storage-location erc7201:robin.storage.Pausable
src/libraries/StorageLib.sol:110:    /// @custom:storage-location erc7201:robin.storage.Signatures
src/libraries/StorageLib.sol:130:    /// @custom:storage-location erc7201:robin.storage.Extension

$ grep -rn "api\.robin" src
(no matches — exit 1)
```

## What's next (not in this pass)

| Phase | Scope |
|---|---|
| 2 | Polygon dependency config, `.env.example`, verify Polymarket addresses (the CTF Exchange V2 and Neg Risk Exchange addresses in `implementation.md` look suspicious and should be re-fetched from official Polymarket docs before any deploy) |
| 3 | `script/DeployPsiFinance.s.sol` |
| 4 | Fork tests against Polygon RPC |
| 5 | Backend skeleton — `psi-terminal-backend/` |
| 6 | Frontend — `psi-terminal-frontend/` |
| 7 | ABI + address export package |
| 8 | Slither / Mythril / role review / signed-withdrawal replay / loss protection review |
| 9 | Mainnet deployment runbook |

## Open questions blocking later phases

1. **Polymarket collateral address** — `underlyingUsdc` could be current `pUSD`, older bridged `USDC.e`, or another wrapper. Must be confirmed from `broadcast/DeployRobinStakingVault.s.sol/137/run-1776211857782.json` (upstream actual deployment) before Phase 3.
2. **`polymarketWcol`** — wrapped collateral address is empty in `.env.example` per `implementation.md`. Same source to confirm.
3. **Neg-risk addresses** — at least two addresses in `implementation.md` look like they may be malformed (non-EIP-55 checksum and unusual `00…00` middle patterns). Re-fetch from https://docs.polymarket.com/resources/contracts before trusting.
4. **Metadata URI host** — `https://api.psi.finance` doesn't exist yet. Phase 2 should switch this to env-driven so dev/staging/prod can each set their own `PSI_METADATA_URI`.

## Build artifacts

`out/` and `cache/` regenerable via `forge build`. Both are in `.gitignore` upstream (inherited).

## Recovery note

During the initial clone attempt, a pre-existing empty `~/.git` (in `/Users/0xpranav/`, dated Apr 16, no commits, no remotes) caused git commands run from inside `psi-contracts/` to operate against the home directory instead. `git reset --hard upstream/main` wrote Robin's tracked tree into `~/` before this was caught. Recovery: the 10 Robin top-level paths (`foundry.toml`, `.gitmodules`, `src/`, `lib/`, `audits/`, `broadcast/`, `licenses/`, `foundry.lock`, `remappings.txt`, `.gitignore`) were verified to be newly-created (timestamps confirmed nothing pre-existed) and surgically removed. The pre-existing `~/.git` was restored to its original empty state (upstream remote removed, HEAD ref deleted, branch ref restored). A fresh `.git` was then initialized inside `psi-contracts/` and the Robin fetch + reset was repeated cleanly. No user data was lost. `~/.git` was left intact per user direction — the home-dir-as-git-repo footgun remains and may trip future tools.
