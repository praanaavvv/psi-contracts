# PSI Finance — Contract Architecture

> Everything you need to read the code without getting lost. Read top-to-bottom on a first pass.

---

## 1. The product in one paragraph

PSI Finance is a **yield-bearing wrapper around Polymarket outcome tokens**. A user holds YES or NO conditional tokens from any Polymarket market; they deposit those tokens into PSI; PSI gives them ERC-1155 "shares" in return; PSI pairs YES+NO tokens together, merges them via the Polymarket CTF into USDC, and parks the USDC in external ERC-4626 yield vaults (Aave, Compound, etc.). When the user withdraws, PSI burns their shares, splits USDC back into YES+NO if it has to, returns their outcome tokens plus their share of accumulated yield. A TWAP oracle decides how that yield gets split between YES and NO holders — if YES was trading at 80¢ for most of the period, YES holders get most of the yield. Loss is shared equally on both sides (because every dollar lost = one fewer YES + one fewer NO that can be produced on withdrawal).

The contract suite is a **fork of `robin-markets/staking-vault-contracts`** rebranded for PSI. See `docs/FORK_CHANGES.md` for the exact rename map.

---

## 2. System map

```
                  ┌────────────────────────────────────────────────────┐
                  │  PsiTimeLockController  (governance delay; OZ wrapper) │
                  └──────────────────────────────────┬─────────────────┘
                                                     │ TIMELOCKED_ROLE → upgrades, twap config, fee param
                                                     │
   ┌─────────────────────┐   ERC1967Proxy            │
   │  PsiTwapOracle      │◄──────────────────┐       │
   │  (UUPS, EIP-712)    │                   │       │
   │  - submitTwap()     │   reads via       │       │
   │  - market state     │   getCurrent…()   │       │
   └─────────┬───────────┘                   │       │
             │ VAULT_ROLE grant              │       │
             ▼                               │       ▼
   ┌─────────────────────────────────────────┴───────────────────────┐
   │  PsiStakingVault  (UUPS, ReentrancyGuard, AccessControl)        │
   │  + AccountingMixin  + PolymarketMixin  + YieldStrategyMixin     │
   │  + SignaturesMixin  + PausableMixin                             │
   │                                                                 │
   │  fallback() ── delegatecall ──┐                                 │
   └───────────────────────────────┼─────────────────────────────────┘
                                   │
                                   ▼
                       ┌───────────────────────────┐
                       │ PsiStakingVaultExtension  │   (admin surface;
                       │ (NOT proxied; called via  │    same storage layout)
                       │  delegatecall fallback)   │
                       └───────────────────────────┘

   PsiLens  ── pure view aggregator over PsiStakingVault for batch RPCs.

   External Polymarket contracts (chain 137):
       ConditionalTokens (CTF) ─── splitPosition / mergePositions / ERC-1155
       NegRiskAdapter         ─── alternative split/merge for multi-outcome markets
       CTF Exchange Registry  ─── used to detect if a market is V1 USDC-backed
       NegRisk CTF Exchange   ─── used to detect if a market is NegRisk WCOL-backed
       USDC.e (collateral) and WCOL (wrapped negrisk collateral)
       PolyFactoryHelper      ─── maps EOA → Poly proxy wallet or Gnosis safe

   External yield vaults (added by EXTERNAL_VAULT_MANAGER_ROLE):
       Any ERC-4626 vault whose underlying is USDC.e.
```

---

## 3. The five deployed contracts

### 3.1 `PsiStakingVault`  (`src/PsiStakingVault.sol`)

**The main user-facing contract.** Singleton — one deployment handles all Polymarket markets. UUPS-upgradeable behind an ERC1967Proxy.

What it composes:
```
PsiStakingVault is
    UUPSUpgradeable, ReentrancyGuard, AccessControlUpgradeable,
    AccountingMixin,        ← shares, indexes, yield, fees
    PolymarketMixin,        ← CTF integration, pair/merge/split
    YieldStrategyMixin,     ← external ERC-4626 vault management
    SignaturesMixin,        ← EIP-712 signed withdrawals
    PausableMixin           ← granular pause flags
```

Public entry points (user actions):
| Function | What it does |
|---|---|
| `deposit(conditionId, yesAmount, noAmount, referralCode)` | Pull YES/NO outcome tokens from user (via CTF), mint ERC-1155 shares, pair anything pairable into USDC, supply USDC to external vaults. |
| `batchDeposit(...)` | Same but across many markets in one tx. |
| `withdraw(conditionId, yesShares, noShares, yieldRecipient, referralCode)` | Burn shares, compute loss-adjusted asset value, withdraw USDC from external vaults as needed, split USDC back into YES+NO if there aren't enough unpaired tokens, send YES/NO + USDC yield to user. |
| `batchWithdraw(...)` | Batch version. |
| `executeSignedWithdrawal(SignedWithdrawal)` | Backend or any caller submits a user-signed EIP-712 withdrawal that runs only if `minYesTokens`/`minNoTokens` are met (limit-order semantics). |
| `invalidateNonces` / `invalidateNonceWord` | Cancel one or up to 256 pending signed withdrawals. |
| `initializeMarket(conditionId)` | First-deposit auto-runs this; public so backend can pre-warm a market. |
| ERC-1155 `safeTransferFrom` / `safeBatchTransferFrom` | Share tokens are themselves transferable (gated by `pausedTransfers`). |

Internal flow worth knowing:
- `_batchDeposit` does **two passes** over the markets: pass 1 mints shares per market and builds the batch transfer arrays; pass 2 pairs YES+NO into USDC and supplies the resulting USDC to vaults.
- `_batchWithdraw` also does two passes: pass 1 burns shares and totals up the USDC needed; pass 2 splits USDC and builds the outgoing transfer arrays. The total USDC need is known **before** any external-vault withdraw, so it's a single withdraw call.
- `_authorizeUpgrade` is restricted to `TIMELOCKED_ROLE` — UUPS upgrades go through `PsiTimeLockController`.
- The `fallback()` is the routing mechanism for admin/view calls that aren't defined on this contract: they delegate to `PsiStakingVaultExtension`.

### 3.2 `PsiStakingVaultExtension`  (`src/PsiStakingVaultExtension.sol`)

**The admin surface.** Not deployed behind its own proxy; called only via `PsiStakingVault.fallback() → delegatecall`. Shares the exact same ERC-7201 storage layout, so `delegatecall` reads/writes the right slots in the proxy's storage.

Why split out:
- Solidity contract bytecode is capped at 24 KB (EIP-170). Putting deposit/withdraw + all admin + all view wrappers in one contract blew past that. Splitting admin into a second contract is a standard pattern.
- The proxy stores `extension` address in `ExtensionStorage` (`StorageLib`). Updating that address is a `TIMELOCKED_ROLE` action — that's how you ship admin upgrades.

What lives on the extension:

| Category | Functions |
|---|---|
| **External vault management** | `addVault`, `removeVault`, `setVaultCap`, `setVaultActive`, `swapVaultOrder`, `supplyIdleToVaults` |
| **Protocol fees** | `setProtocolFeeBps` (timelock), `harvestProtocolFee` (sends fees to a recipient) |
| **TWAP wiring** | `setTwapGracePeriod`, `setTwapOracle` |
| **Emergency** | `enableEmergencyMode`, `disableEmergencyMode`, `enableVaultEmergency`, `disableVaultEmergency`, `withdrawMaxDuringEmergency` |
| **Pause** | `setPauseAll`, `setPauseDeposits`, `setPauseWithdrawals`, `setPauseTransfers` |
| **Metadata** | `setUri` |
| **View wrappers** | `getMarketState`, `getUserShares`, `getUserAssets`, `getUserYield`, `previewDeposit`, `previewWithdraw`, `getExternalVaults`, `getTotalUsdcValue`, … (these are the "external getters" the frontend/backend call) |

You will call these against the **proxy address** in practice. The proxy's fallback routes them to the extension's bytecode.

### 3.3 `PsiTwapOracle`  (`src/PsiTwapOracle.sol`)

**The price feed.** Separate UUPS proxy. Its job is to maintain a `twapAccumulatorYes` per market — a running sum of `(twapPriceYes * timeDelta)` — that the vault uses to fairly distribute yield between YES and NO holders.

Roles:
- `DEFAULT_ADMIN_ROLE` / `DEFAULT_MANAGER_ROLE` → both granted to the owner at init.
- `TIMELOCKED_ROLE` → controls UUPS upgrades.
- `VAULT_ROLE` → must be granted to `PsiStakingVault` proxy *after* deploy. That's why the deploy script's final step is `grantRole(VAULT_ROLE, vaultProxy)`. Only `VAULT_ROLE` can call `initializeMarket`.

Key functions:
| Function | What |
|---|---|
| `initializeMarket(conditionId, yesPositionId, noPositionId, negRisk)` | Called by the vault on first deposit. Stamps init time. |
| `submitTwap(BatchTwapData)` | Anyone can submit a TWAP update, but the backend signer's signature is required for any market where `isTwapSignatureRequired(conditionId) == true`. For finalized markets, signature can be skipped (so the contract can wind down without the signer needing to run forever). |
| `getCurrentTwapAccumulator(conditionId)` | View that returns the on-chain accumulator, extended to `block.timestamp` with either the finalized price or the 50:50 default if TWAP isn't required. Used by `AccountingLib.getTwapAccumulatorYes`. |
| `pause / unpause`, `setTwapSigner`, `setDefaultTwapRequired`, `setGlobalTwapRequired`, `setGlobalTwapDisabled`, `setMarketTwapRequired` | Manager controls. |

TWAP requirement priority (line 209-214):
```
globalTwapDisabled (kill switch)  >  globalTwapRequired (force-on)  >  per-market market.twapRequired
```

`globalTwapDisabled = true` is a circuit breaker: if the oracle signer ever fails permanently, governance can disable TWAP across all markets, and the system falls back to a 50:50 yield split.

### 3.4 `PsiTimeLockController`  (`src/PsiTimeLockController.sol`)

A 17-line wrapper around OpenZeppelin's `TimelockController` with one tweak: it passes `address(0)` as the admin to OZ's constructor, which means **there is no admin role** that can bypass the timelock. Only the configured proposers can schedule operations, only the configured executors can execute them, and operations only become executable after `minDelay` seconds.

What goes through the timelock:
- `_authorizeUpgrade` on both `PsiStakingVault` and `PsiTwapOracle` (UUPS upgrades).
- `setExtensionAddress` on the vault (pointing the fallback at a new extension contract).
- `setProtocolFeeBps`.

What does **not** go through the timelock: pause, vault add/remove, fee harvest, twap signer rotation, ERC-1155 URI. Those are direct admin calls for ops speed.

### 3.5 `PsiLens`  (`src/PsiLens.sol`)

Pure-view aggregator. Not proxied. Constructor takes the vault proxy address. Everything it does is a `view` function that loops over a batch of `conditionIds` and calls the vault's own view functions. Useful for portfolio page loads — one RPC call returns N markets' worth of data:

| Function | Returns |
|---|---|
| `batchGetUserShares` | YES/NO shares per market |
| `batchGetUserAssets` | Loss-adjusted asset value per market |
| `batchGetUserYield` | Pending USDC yield per market (needs caller-supplied TWAP price) |
| `batchGetUserPortfolio` | Combines the above three |
| `batchPreviewDeposit` / `batchPreviewWithdraw` | What-if calculators |
| `batchGetMarketState` / `batchGetMarketIndexes` | Market-level data |
| `checkBatchDepositCapacity` | Simulates a hypothetical batch deposit against vault caps; returns `bool` so the frontend can disable the "Deposit" button without sending a tx. |

---

## 4. The five mixins (combine to form `PsiStakingVault`)

Mixins are abstract contracts that hold a slice of state + logic. `PsiStakingVault` inherits all five. Each mixin keeps its state in its own ERC-7201 namespace so they don't collide. Most of them are thin: the **heavy logic lives in matching external libraries** (`AccountingLib`, `VaultLib`, `PolymarketLib`) that get `DELEGATECALL`-ed from the mixin to keep the proxy under 24 KB.

### 4.1 `AccountingMixin`  (`src/mixins/AccountingMixin.sol`)

ERC-4626-like per-side accounting backed by ERC-1155 share tokens.

What it owns (storage namespace `robin.storage.Accounting`):
- `markets[conditionId]` → full `MarketState` (10 storage slots — see DataTypes for layout)
- `userStates[user][conditionId]` → user's yield snapshots
- `totalPoolShares`, `totalPoolAssets` — the **global USDC pool** that aggregates all markets
- `protocolFeeBps`, `accumulatedProtocolFees`
- `twapOracle`, `twapGracePeriod`
- `tokenInfo[tokenId]` → reverse lookup from ERC-1155 token ID to `(conditionId, side)`

Key concepts you have to internalize:

1. **Token ID = `keccak256(conditionId, side)`**. So every (market, YES/NO) pair has a unique ERC-1155 ID. PSI shares are themselves transferable ERC-1155 tokens.

2. **Two indexes per side, per market**:
   - **`lossIndex`** starts at `1e18` (= `INDEX_SCALE`) and only **decreases**, when the external vault loses USDC. `assets = shares × lossIndex / 1e18`. When `lossIndex = 0.5e18`, your shares are worth half their original token amount.
   - **`yieldPerShare`** starts at 0 and only **increases**, accumulating USDC yield per share. Your earned yield is `(yieldPerShare - yourSnapshot) × yourShares / 1e18`.

3. **Yield snapshot per user per market**: when you deposit, the contract records the current `yieldPerShareYes` / `yieldPerShareNo` as your snapshot. You only earn yield accrued after your snapshot, so late depositors don't dilute earlier ones. On additional deposits, the snapshot is updated to a **weighted average** so each share is correctly tracked. On transfers, the receiver's snapshot is blended with the sender's so the yield claim transfers with the shares.

4. **`yieldReductionFactor`** kicks in only when loss exceeds what the token pair backing can absorb. If loss > `min(YES_tokens, NO_tokens)`, the excess can't be eaten by `lossIndex` (which may already be 0); instead `yieldReductionFactor` shrinks below 1.0 to take it out of outstanding yield claims. This keeps the contract solvent at the edge.

5. **The TWAP grace period** (`MAX_TWAP_GRACE_PERIOD = 120s`): every share-changing operation calls `_updateYieldIndexes(conditionId)`, which fetches the current TWAP accumulator from the oracle. If the accumulator is more than `gracePeriod` seconds stale, the call **reverts** — the user (or the backend on their behalf) must submit a fresh TWAP first. This protects against using badly stale prices to compute yield splits.

The mixin's external functions are mostly internal helpers prefixed with `_` (the public surface is implemented on the extension as view wrappers). The mixin holds the abstract `_getTotalPoolAssetsCurrent()` and `_getReservedUsdc()` — both overridden in the vault to add the protocol-fee reservation and current vault valuations.

### 4.2 `PolymarketMixin`  (`src/mixins/PolymarketMixin.sol`)

CTF integration layer. Storage namespace `robin.storage.Polymarket`.

What it owns:
- `ctf`, `negRiskAdapter`, `negRiskCtfExchange`, `ctfExchange` — the four external Polymarket contracts
- `underlyingUsdc`, `polymarketWcol` — collateral addresses
- `tokenInfo[conditionId]` → cached `PolymarketTokenInfo` (yes/no position IDs, negRisk flag, which collateral)
- `maximumAdditionalMatchedTokens` — running total of "if all unpaired tokens across all markets were perfectly paired, how much USDC would land in external vaults?" Used for capacity checks.

Six operations:
| Op | What |
|---|---|
| `_initializePolymarketInfo` | First-deposit-only: validates 2 outcome slots, derives YES/NO position IDs, auto-detects negRisk vs regular by querying both exchange registries (see `_decideVaultMode` / `_listedOn` in `PolymarketLib`). |
| `_takeOutcomeTokens` | Batch transfer outcome tokens from user → vault via CTF (requires user's `setApprovalForAll`). |
| `_giveOutcomeTokens` | Batch transfer from vault → user. |
| `_pairAndMerge` | Look at current YES/NO balances, pair the minimum, call CTF `mergePositions(YES+NO → USDC)`. |
| `_split` | Call CTF `splitPosition(USDC → YES+NO)`. Used during withdrawal when there aren't enough unpaired tokens to satisfy the user. |
| `_updateMaxPotential` | Bookkeeping for the capacity tracker described above. |

The `negRisk` distinction matters: NegRisk markets use a separate `NegRiskAdapter` and a different collateral (`WCOL`). The mixin holds the wrappers; the heavy lifting (auto-detection, split/merge, max-potential tracking) is in `PolymarketLib`.

### 4.3 `YieldStrategyMixin`  (`src/mixins/YieldStrategyMixin.sol`)

External ERC-4626 vault management. Storage namespace `robin.storage.YieldStrategy`.

What it owns:
- `vaults[]` — ordered array of `ExternalVault` configs (vault address, cap, active, emergencyActivated)
- `vaultIndex[vault]` → 1-indexed position in the array (so `0` = not present)
- `underlyingUsdc` — must match every vault's underlying asset
- `emergencyMode` — global flag

Two flows:

**Supply (vault → external)**: `_supplyToVaults()` walks vaults in array order and deposits idle USDC into each up to its cap, until either USDC runs out or all caps are full. There's a strict version (`supplyToVaults` reverts if it can't supply everything — used in the deposit happy path after capacity is pre-checked) and a forgiving version (`trySupplyIdleToVaults` returns the leftover — used in admin "supply whatever fits" calls).

**Withdraw (external → vault)**: `_withdrawFromVaults(amount)` walks vaults in **reverse** order (LIFO-like) and pulls from each, reverting if there's insufficient total liquidity. `_ensureUsdcBalance(amount)` is the smarter wrapper: if the contract already has `amount` USDC idle it doesn't withdraw, and if there's excess idle it tries to push it back to vaults.

**Emergency mode**: `enableEmergencyMode()` pulls every USDC out of every vault and sets a flag that prevents future supplies. There's also per-vault emergency (`enableVaultEmergency`) for when only one of the vaults is compromised — that one gets fully withdrawn, others keep running.

All actual `IERC4626.deposit/withdraw/redeem` calls live in `VaultLib` and are delegate-called.

### 4.4 `SignaturesMixin`  (`src/mixins/SignaturesMixin.sol`)

EIP-712 signature verification for **signed withdrawals** — limit-order semantics. Storage namespace `robin.storage.Signatures`.

What it owns:
- `polymarketFactoryHelper` — used to map an EOA to its Polymarket proxy wallet or Gnosis safe address (some Polymarket users sign from EOAs but their position is in a proxy/safe).
- `nonceBitmap[user][wordPos]` — packed nonce tracking. Each `uint256` word holds 256 nonce slots. Setting bit `nonce % 256` of word `nonce / 256` marks that nonce as consumed.

The signed withdrawal flow:
1. User signs an EIP-712 `SignedWithdrawal` struct with: conditionId, shares, `minYesTokens`/`minNoTokens`, `protectAgainstLoss`, `expiry`, `nonce`, `signatureType`, etc.
2. Backend stores the signature.
3. Backend monitors Polymarket pricing; when conditions are favorable it calls `executeSignedWithdrawal(signedWithdrawal)`.
4. The contract checks expiry, checks nonce isn't used, verifies the EIP-712 signature, marks the nonce used, then runs `_batchWithdraw(user, …)`.
5. If `protectAgainstLoss=true` and `yesAssets < minYesTokens` or `noAssets < minNoTokens`, the whole tx reverts (the limit wasn't actually hit at execution time).

Why three signature types (`EOA`, `POLY_PROXY`, `POLY_GNOSIS_SAFE`)? Polymarket users often sign from an EOA but the actual wallet that holds positions is a proxy or Gnosis safe owned by that EOA. The mixin queries `PolyFactoryHelper.getPolyProxyWalletAddress(signer)` or `getSafeAddress(signer)` to validate that `signer` is authorized to act on behalf of `user`.

User can cancel with `invalidateNonces([n])` or `invalidateNonceWord(wordPos)` — the latter cancels 256 orders at once.

### 4.5 `PausableMixin`  (`src/mixins/PausableMixin.sol`)

Four independent pause flags + two modifiers (`whenDepositsNotPaused`, `whenWithdrawalsNotPaused`). Transfers have their own check inside the ERC-1155 `_update` override on the main contract. Storage namespace `robin.storage.Pausable`.

| Flag | Effect |
|---|---|
| `pausedAll` | All four operations refuse. |
| `pausedDeposits` | `deposit`/`batchDeposit` revert. |
| `pausedWithdrawals` | `withdraw`/`batchWithdraw`/`executeSignedWithdrawal` revert. |
| `pausedTransfers` | ERC-1155 share transfers revert (deposits/withdrawals still work). |

All four are settable by `PAUSER_ROLE` via extension functions. The granularity means you can halt new deposits while still letting users exit.

---

## 5. The seven libraries

There are two flavors of library in this repo. The distinction matters for understanding bytecode.

**External delegate-called libraries** (`AccountingLib`, `PolymarketLib`, `VaultLib`): these are deployed as their own contracts and called via Solidity's automatic `DELEGATECALL` when a `library` has at least one `external`/`public` function. They access the vault's storage directly via the same ERC-7201 slot constants. Their purpose: shrink the main contract's bytecode.

**Pure embedded libraries** (`IndexCalcLib`, `TwapMath`, `ShareMath`): these have only `internal` functions. The compiler **inlines** them into whoever imports them. They're pure math helpers — no storage access.

### 5.1 `AccountingLib`  (`src/libraries/AccountingLib.sol`)

External library called by `AccountingMixin`. Heavy storage logic lives here.

- `getTokenId(conditionId, side)` — `uint256(keccak256(abi.encodePacked(conditionId, uint8(side))))`. Deterministic, no collisions across markets.
- `initializeMarket` — stamps init timestamp, sets `lossIndex = 1e18` on both sides, sets `yieldReductionFactor = 1e18`, registers the two token IDs in the reverse-lookup map, calls `twapOracle.initializeMarket(…)`.
- `addToPool(conditionId, amount)` / `removeFromPool` — the **per-market share of the global USDC pool**. Each market gets `marketPoolShares` proportional to how much USDC it contributed; as the global `totalPoolAssets` grows (yield) or shrinks (loss), each market's slice scales with it. `ShareMath.assetsToShares` with virtual offset = 1 (anti-inflation).
- `updateYieldIndexes(conditionId)` — the **central accounting heartbeat**. Reads the TWAP accumulator (reverts if stale), calls `IndexCalcLib.calculateIndexes`, and writes the resulting `lossIndexYes/No`, `yieldPerShareYes/No`, `yieldReductionFactor`, and `principalContributed` back to storage. Bumping `principalContributed = marketValue` is what prevents re-counting the same gain or loss.
- `mintShares(user, conditionId, side, assets, oldShares)` — converts assets → shares at the current loss index, updates `totalShares`, blends the user's yield snapshot via weighted-average, and returns `(shares, tokenId)` for the mixin to actually `_mint`.
- `burnShares` — inverse. Returns `(tokenAssets, yieldUsdc, tokenId)`. Note: `tokenAssets` is the **outcome-token amount** (loss-adjusted), and `yieldUsdc` is the **USDC yield** — they're computed separately because the mixin needs to know how much USDC to extract from external vaults before returning anything.
- `handleTransferAccounting(from, to, tokenId, sharesTx, receiverShares)` — when shares are transferred between users, the receiver's yield snapshot is blended with the sender's, so the *yield claim* attached to those shares travels along.

### 5.2 `PolymarketLib`  (`src/libraries/PolymarketLib.sol`)

External library called by `PolymarketMixin`.

- `initializePolymarketInfo(conditionId)` — auto-detects market type by checking both exchange registries (`_decideVaultMode` / `_listedOn`). NegRisk markets use `WCOL` collateral and the `NegRiskAdapter`; regular markets use `USDC.e` and the standard CTF `splitPosition`/`mergePositions`. Reverts if the market isn't listed on either.
- `takeOutcomeTokens` / `giveOutcomeTokens` — batch `safeTransferFrom` on the CTF. Single-token transfers are optimized to a non-batch call.
- `split(conditionId, usdcAmount)` — calls CTF or NegRiskAdapter `splitPosition` depending on `info.negRisk`. After the split, both sides hold `usdcAmount` of YES tokens and `usdcAmount` of NO tokens.
- `pairAndMerge(conditionId)` — looks at current unpaired YES/NO balances (read via `ctf.balanceOf(this, positionId)`), takes the minimum, calls `mergePositions` to convert that many pairs back into USDC. Returns the USDC received.
- `_updateMaxPotential(oldYes, oldNo, newYes, newNo)` — bookkeeping for the global capacity tracker (`maximumAdditionalMatchedTokens`). When a side's max changes, the delta gets added or subtracted from the running total. This is what the deposit-time capacity check compares against external vault caps.

### 5.3 `VaultLib`  (`src/libraries/VaultLib.sol`)

External library called by `YieldStrategyMixin`. All the actual `IERC4626` calls live here.

Vault management: `addVault` (validates ERC-4626 underlying matches `underlyingUsdc`, infinite-approves, kicks off a try-supply), `removeVault` (withdraws everything via `redeem`, removes approval, redistributes), `setVaultCap`, `setVaultActive`, `swapVaultOrder` (order = priority).

Supply/withdraw helpers:
- `_trySupplyToVaults(amount, …)` — walks `vaults[]` in order, deposits up to each one's `_getAvailableCapacity` (which respects both the vault's own `maxDeposit` and the user-set `cap`), returns leftover. Skips inactive/emergency vaults.
- `_withdrawFromVaults(amount)` — walks `vaults[]` in **reverse** order, pulls from each up to its `maxWithdraw(this)`. Reverts with `InsufficientLiquidity` if it can't get the full amount.
- `_withdrawMaxFromVault(vault)` — non-reverting helper used in emergency flows.
- `_withdrawAllFromVault(vault)` — reverting helper used during `removeVault`; uses `redeem(shares, …)` not `withdraw(amount, …)` to drain the position completely.

Idle = `IERC20(usdc).balanceOf(this) - reservedUsdc`. The `reservedUsdc` parameter is plumbed in from the caller (the mixin overrides `_getReservedUsdc` to return `accumulatedProtocolFees`, ensuring fee-earmarked USDC isn't supplied to external vaults).

Capacity views:
- `getTotalAvailableCapacity` — sums available capacity across active, non-emergency vaults, subtracts already-idle USDC.
- `getTotalAvailableInternalCapacity` — same but using user-set `cap` only (ignores the vault's own `maxDeposit`). Used in the deposit-time forward-looking check: "if all currently unpaired tokens were paired into USDC, would there be room?"

### 5.4 `IndexCalcLib`  (`src/libraries/IndexCalcLib.sol`)

Pure (embedded) library — no storage. `calculateIndexes(market, input)` is the math engine for yield/loss distribution.

Logic in plain English:
1. Compute `marketValue` = this market's current slice of the global pool (`marketPoolShares × totalPoolAssets / totalPoolShares`).
2. Compare `marketValue` to `principalContributed`. If equal, nothing to do.
3. If `marketValue > principalContributed` → **gain**. Only `yieldPerShare` increases. The gain is split between YES and NO using TWAP-weighted assets — `splitYieldWeighted(delta, twapAccumDelta, timeDelta, yesBaseline, noBaseline)` in `TwapMath`. The intuition: if YES averaged 80¢ and NO averaged 20¢ over the period, YES holders earn 4× more yield per dollar of asset.
4. If `marketValue < principalContributed` → **loss**. Both sides take the same loss (because the pool's USDC backs USDC, which can split 1:1 into YES+NO). Both `lossIndex` values decrease equally. If the loss exceeds the pairable tokens that the vault could possibly produce on withdraw, the excess is taken out of outstanding yield claims via `_applyExcessLossReduction` — scales `yieldReductionFactor` down so that `reducedTotalYield = trueTotalYield - excessUsdc`.

The two-mode `twapPriceYes` parameter in `calculateIndexes` is a clever optimization:
- If `twapPriceYes <= PRICE_SCALE`: **view-function path**. Simulate the TWAP accumulator extending to `block.timestamp` at that price — gives the frontend a real-time yield estimate without sending a tx.
- If `twapPriceYes > PRICE_SCALE` (sentinel value `PRICE_SCALE + 1`): **mutating path**. Use the stored accumulator as-is — TWAP was already updated before calling.

### 5.5 `TwapMath`  (`src/libraries/TwapMath.sol`)

Pure library. Three things:

- `splitYieldWeighted(totalYield, twapAccYesDelta, timeDelta, yesAssets, noAssets)` — splits a yield amount between YES and NO using `(yesAssets × twapAccYesDelta)` vs `(noAssets × twapAccNoDelta)` as proportional weights. `twapAccNoDelta = (timeDelta × PRICE_SCALE) - twapAccYesDelta`. Edge cases (one side empty, time = 0, total = 0) fall back to 50:50.
- `_validateTwapData(data, lastUpdate)` — checks timing (start ≤ lastUpdate, end ≤ now, end ≥ start) and price range (≤ `PRICE_SCALE`).
- `defaultPrice()` = `PRICE_SCALE / 2` = `5e5` = 50% — used when TWAP isn't required for a market.

### 5.6 `ShareMath`  (`src/libraries/ShareMath.sol`)

Pure library. ERC-4626-style asset↔share conversion. Uses a **virtual offset of 1** on both numerator and denominator to prevent the first-depositor inflation attack (a classic ERC-4626 issue) and divide-by-zero. Two pairs of functions: `assetsToShares` / `sharesToAssets` (pool-style, takes `totalAssets`/`totalShares`) and `assetsToSharesWithIndex` / `sharesToAssetsWithIndex` (index-style, takes a single `yieldIndex` scaled by `1e18`).

### 5.7 `StorageLib`  (`src/libraries/StorageLib.sol`)

Not deployed. **Single source of truth for all ERC-7201 namespaced storage** — every struct, every slot constant, every accessor. Both the mixins inside `PsiStakingVault` AND `PsiStakingVaultExtension` AND the three external libraries (`AccountingLib`, `PolymarketLib`, `VaultLib`) import from here, so they all read/write the same slots in the proxy's storage.

The six namespaces:

| Slot label | Lives in | What's there |
|---|---|---|
| `robin.storage.Accounting` | AccountingMixin / AccountingLib | markets, userStates, pool totals, fees, twap config, tokenInfo |
| `robin.storage.YieldStrategy` | YieldStrategyMixin / VaultLib | external vault list, vaultIndex, emergencyMode, underlyingUsdc |
| `robin.storage.Polymarket` | PolymarketMixin / PolymarketLib | ctf, adapters, exchanges, collateral addresses, max-potential tracker, per-market token info |
| `robin.storage.Pausable` | PausableMixin | four bool flags |
| `robin.storage.Signatures` | SignaturesMixin | polymarketFactoryHelper, nonceBitmap |
| `robin.storage.Extension` | (read by main vault's fallback) | the extension contract address |

These names were intentionally **kept as `robin.storage.*`** during the fork rebrand (see `docs/FORK_CHANGES.md`). They're internal-only strings whose only job is to derive the keccak storage slot — renaming them would shift every contract's storage layout for no user-visible benefit.

---

## 6. Types and roles

### `DataTypes`  (`src/types/DataTypes.sol`)

Pure library of constants, enums, and structs. Notables:

- `BPS_DENOM = 10_000` (100% in basis points)
- `PRICE_SCALE = 1e6` (100% for TWAP prices — `5e5` = 50%)
- `INDEX_SCALE = 1e18` (1.0 for loss/yield indexes)
- `YES_INDEX_SET = 1` / `NO_INDEX_SET = 2` — Polymarket CTF partition bitmasks
- `enum Side { YES, NO }`
- `struct MarketState` — 10 slots, gas-packed (uint128 pairs for indexes, uint40 for timestamps)
- `struct InitParams` — what the deploy script encodes for `vault.initialize`
- `struct TwapData`, `struct BatchTwapData` — signed by the TWAP backend
- `struct SignedWithdrawal` + `enum SignatureType { EOA, POLY_PROXY, POLY_GNOSIS_SAFE }` — limit-order shape
- A handful of "keep stack depth low" helper structs (`BatchDepositVars`, `BatchWithdrawVars`, `WithdrawBurnResult`, `YieldCalcLocals`, `IndexCalcInput`, `IndexResult`)

### `Roles`  (`src/types/Roles.sol`)

Just the five role constants (the sixth, `VAULT_ROLE`, is defined on `PsiTwapOracle`):

| Role | Holders | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (OZ built-in) | `PSI_OWNER` (typically a multisig) | Grants/revokes other roles |
| `DEFAULT_MANAGER_ROLE` | `PSI_OWNER` | TWAP grace period, TWAP oracle swap, ERC-1155 URI |
| `FEE_HARVESTER_ROLE` | `PSI_OWNER` | `harvestProtocolFee` |
| `TIMELOCKED_ROLE` | `PsiTimeLockController` only | UUPS upgrades, extension swap, fee BPS |
| `PAUSER_ROLE` | `PSI_OWNER` | Set any of the 4 pause flags |
| `EXTERNAL_VAULT_MANAGER_ROLE` | `PSI_OWNER` | Add/remove/cap/reorder external vaults, emergency mode |
| `VAULT_ROLE` (on oracle) | `PsiStakingVault` proxy | `initializeMarket` on the oracle |

`TIMELOCKED_ROLE` is **self-administered** (`_setRoleAdmin(TIMELOCKED_ROLE, TIMELOCKED_ROLE)`) — meaning only the timelock itself can grant or revoke this role, so the owner can't bypass timelocked operations by re-granting the role.

---

## 7. External Polymarket interfaces

| Interface | What |
|---|---|
| `IConditionalTokens` | The Polymarket CTF (ERC-1155). `prepareCondition`, `splitPosition`, `mergePositions`, `redeemPositions`, `getConditionId`, `getCollectionId`, `getPositionId`. PSI calls `split`/`merge` to convert between USDC and YES+NO tokens. |
| `INegRiskAdapter` | Wrapper around CTF for multi-outcome markets where only one outcome can resolve true. Same split/merge interface but routes through the adapter with `WCOL` as the wrapped collateral. |
| `IRegistry` | The exchange registries (`ctfExchange` for V1 USDC-backed, `negRiskCtfExchange` for NegRisk). PSI uses these only as read-only — `getConditionId(tokenId)` and `getComplement(tokenId)` — to auto-detect whether a market is regular or NegRisk. |
| `IPolyFactoryHelper` | 8 lines. Maps an EOA → its Polymarket proxy wallet or Gnosis safe address. Only used in `SignaturesMixin._verifySignerForUser`. |

---

## 8. End-to-end flows

### 8.1 Deposit

```
1. User calls CTF.setApprovalForAll(vaultProxy, true)        — one-time
2. User calls vault.deposit(conditionId, yesAmt, noAmt, ref)
3. vault._batchDeposit:
   a. _updatePoolAssets(_getTotalUsdcValue())  ← sync pool snapshot
   b. For each market:
        - _initializePolymarketInfo if first deposit
        - _updateMaxPotential (capacity bookkeeping)
        - _updateYieldIndexes (reverts if TWAP stale)
        - _mintShares(YES) and/or _mintShares(NO) → ERC-1155 _mint
        - record (positionId, amount) into batch transfer arrays
   c. _takeOutcomeTokens — single CTF.safeBatchTransferFrom pulls all tokens
   d. For each market: _pairAndMerge + _addToPool
   e. Capacity check: maxPotential ≤ internal capacity
   f. _supplyToVaults → IERC4626.deposit
   g. emit Deposited(...)
```

### 8.2 Withdraw

```
1. User calls vault.withdraw(conditionId, yesShares, noShares, recipient, ref)
2. vault._batchWithdraw — two passes:

   PASS 1 (compute):
     For each market:
        - _updateYieldIndexes
        - _burnShares(YES/NO) → (tokenAssets, yieldUsdc); ERC-1155 _burn
        - splitNeeded = max(yesShortfall, noShortfall)   ← because splitting X
                                                            USDC gives X YES + X NO,
                                                            so we only need max
        - _removeFromPool(splitNeeded + yieldNeeded)

   _ensureUsdcBalance(totalUsdcNeeded)   ← single batch withdraw from ERC-4626

   PASS 2 (settle):
     For each market:
        - _split if splitNeeded > 0  ← CTF.splitPosition(USDC → YES+NO)
        - _updateMaxPotential
        - append to batch transfer arrays
     _giveOutcomeTokens — single CTF.safeBatchTransferFrom to user
     _handleYieldPayout — subtract protocol fee, send remaining USDC yield

3. emit Withdrawn(...)
```

### 8.3 Signed withdrawal (limit order)

```
Off-chain:
  User signs EIP-712 SignedWithdrawal { conditionId, shares, minYesTokens,
                                        minNoTokens, protectAgainstLoss,
                                        expiry, nonce, signatureType, ... }
  → posts to backend.

Backend:
  Watches the market price. When price hits the limit, calls
  vault.executeSignedWithdrawal(signedWithdrawal).

On-chain (vault):
  1. _verifyAndConsumeSignedWithdrawal:
       - expiry > block.timestamp
       - nonce bit not set in user's bitmap
       - ECDSA.recover(EIP-712 digest, sig) == signer
       - signer authorized for user (EOA / POLY_PROXY / POLY_GNOSIS_SAFE)
       - set the nonce bit (replay-protection)
  2. _executeSignedWithdrawalInternal → _batchWithdraw(user, ...)
  3. If protectAgainstLoss and (received YES < minYes OR received NO < minNo):
       revert WithdrawalWouldResultInLoss()
  4. emit SignedWithdrawalExecuted
```

### 8.4 TWAP submission

```
Backend (PSI_TWAP_SIGNER):
  For each active conditionId:
    - Pull Polymarket orderbook / last trade for the period
    - Compute time-weighted-average YES price (0 .. 1e6)
    - Pack into TwapData; build BatchTwapData[]; sign EIP-712 (BATCH_TWAP_TYPEHASH)
  Send PsiTwapOracle.submitTwap(batchTwapData).

Oracle:
  For each market in the batch:
    - skip if not initialized
    - _processTwapForMarket:
        finalized → only allowed if twap.marketEndedAt > 0 → _applyFinalTwap
        not required (and not finalized) → _applyDefaultTwap (50:50)
        required and not finalized → _validate timing + price; _applyTwap
                                     (twapAccumulatorYes += price × timeDelta)
  If any market needed signature verification → check ECDSA against twapSigner.
```

This update is what the vault's `_updateYieldIndexes` reads on its next operation. If TWAP is more than `gracePeriod` (default 60s, max 120s) stale, vault operations on that market revert — the backend (or the user, technically — `submitTwap` is permissionless when valid) must push fresh data first.

---

## 9. Upgradeability and the extension pattern

Three pieces of upgradeable infrastructure:

1. **`PsiStakingVault` UUPS proxy.** New implementation = new contract code. `_authorizeUpgrade` is `onlyRole(TIMELOCKED_ROLE)`, so upgrades flow through `PsiTimeLockController` with the configured `minDelay`.

2. **`PsiTwapOracle` UUPS proxy.** Same pattern.

3. **`PsiStakingVaultExtension` swap.** The vault's `fallback()` reads `ExtensionStorage.extension` and `DELEGATECALL`s to whatever address is stored there. To ship a new admin surface, deploy a new extension contract and have the timelock call `setExtensionAddress(newExtension)`. No proxy involved — the extension is just a logic contract reused by the proxy via the fallback. **Critical constraint**: the new extension must use the same ERC-7201 storage layout. Adding new state means adding a new namespace, never re-using a slot.

`/// @custom:oz-upgrades-unsafe-allow constructor` on both `PsiStakingVault` and `PsiTwapOracle` constructors is the OZ upgrade-plugin marker — these contracts disable their initializer in the constructor so a deployer can't initialize the implementation directly (only the proxy can).

---

## 10. Design choices and risks worth flagging

1. **Storage layout is sacred.** Six ERC-7201 namespaces, slot constants hardcoded in `StorageLib`. Reordering struct fields, renaming namespaces, or removing storage entries will silently corrupt deployed state. Any future contract change has to preserve the layout (append-only).

2. **The vault, the extension, and the three external libraries all share the same proxy storage.** All five enter via `delegatecall` ultimately — the extension via the proxy's fallback, the libraries because Solidity compiles external library calls to `delegatecall`. The slot constants in `StorageLib` are the only thing keeping that coordinated.

3. **`deployer == owner` is required for the initial deploy** (the deploy script asserts this). The post-init `grantRole(VAULT_ROLE, vaultProxy)` on the oracle is signed by the deployer; for that call to land, the deployer needs `DEFAULT_ADMIN_ROLE`, which `initialize` grants only to `initialOwner`. After deploy, transferring admin to a multisig is a separate operation.

4. **TWAP signer is high-value.** The address in `PsiTwapOracle.twapSigner` controls how yield gets split between YES and NO across every market. Compromise = attacker can shift yield to themselves over multiple withdrawals. Mitigations: `globalTwapDisabled` kill switch, `setTwapSigner` rotation, the `gracePeriod` reverts.

5. **Excess loss reduction** (`yieldReductionFactor`) keeps the contract solvent at the edge but is subtle. When `lossIndex` hits 0 on either side, further losses eat into yield claims. Make sure you read `IndexCalcLib._applyExcessLossReduction` before changing anything in `AccountingLib.updateYieldIndexes`.

6. **External vault risk.** ERC-4626 vaults can lose principal, halt withdrawals, get exploited. PSI's mitigations: per-vault caps, active/inactive flag, per-vault and global emergency modes, `withdrawMaxDuringEmergency` to drain whatever can be drained. There's no on-chain check that a vault is "safe" — that's a governance / multisig decision at `addVault` time.

7. **Polymarket dependency.** PSI fully depends on CTF semantics (split = 1 USDC → 1 YES + 1 NO; merge = inverse). If Polymarket changes contracts (V1 → V2), PSI does not auto-detect — see `docs/POLYGON_DEPS.md` for why we pin to V1.

8. **Reentrancy.** `PsiStakingVault` is `ReentrancyGuard`; all user-touchable entry points are `nonReentrant`. CTF transfers are ERC-1155 with `safeTransfer` callbacks, so reentry surface is real. Don't add unguarded entry points.

9. **ERC-1155 metadata URI is hardcoded** to `https://api.psi.finance/v1/shares/{id}` in `PsiStakingVault.initialize`. The deploy script overrides it via `setUri` if `PSI_METADATA_URI` env differs — but mainnet deploy will bake the production URL. A future contract version should accept the URI as an `InitParams` field.

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **conditionId** | Polymarket's ID for a market (`bytes32`). Derived from oracle + questionId + outcomeSlotCount. |
| **position ID** | ERC-1155 token ID inside the CTF for a specific outcome of a specific market. Computed from collateral + collectionId. |
| **collectionId** | A bitmask-encoded combination of (conditionId, outcome partition). YES is index set 1, NO is index set 2. |
| **CTF** | Conditional Tokens Framework — Polymarket's underlying market mechanism. Splitting 1 USDC creates 1 YES + 1 NO; merging both back gives 1 USDC. |
| **NegRisk** | Polymarket's multi-outcome market type where only one outcome can resolve true. Uses a separate adapter contract and `WCOL` (wrapped collateral). |
| **share** | PSI's ERC-1155 receipt token. Token ID = `keccak256(conditionId, side)`. `assets = shares × lossIndex / 1e18`. |
| **lossIndex** | Per-(market, side) index that starts at `1e18` (=1.0) and only decreases when the external vault loses USDC. |
| **yieldPerShare** | Per-(market, side) cumulative USDC yield per share. Increases on gain. |
| **yield snapshot** | Per-user-per-market record of `yieldPerShare` at deposit time. Yield earned = `(current - snapshot) × shares / 1e18`. |
| **yieldReductionFactor** | Scales down outstanding yield claims when losses exceed pairable token backing. Solvency rail. |
| **TWAP** | Time-weighted average price. PSI stores `twapAccumulatorYes` = Σ(price × timeDelta) and divides by total time to get the avg. Used to weight yield split between YES and NO. |
| **PRICE_SCALE** | `1e6`. 100% = 1e6, 50% = 5e5. |
| **INDEX_SCALE** | `1e18`. 1.0 = 1e18. |
| **BPS_DENOM** | `10_000`. 100% in basis points. |
| **pool** | The global USDC pool across all markets. Each market gets `marketPoolShares` proportional to its USDC contribution. Yield/loss propagates through this share ratio. |
| **paired tokens** | YES+NO tokens held by the vault in equal amount. Can be merged back to USDC. |
| **unpaired tokens** | The excess on one side that has no NO/YES counterpart yet. Stays on the vault's balance until either someone deposits the opposite side or the vault splits USDC to fill the gap on withdrawal. |
| **signed withdrawal** | EIP-712-signed off-chain authorization for a withdrawal with optional `minYesTokens`/`minNoTokens` limits. Backend executes when conditions are met. Limit-order semantics. |
| **PSI_TWAP_SIGNER** | EOA whose signature the oracle requires for `submitTwap` on markets where TWAP is required. Held by a backend signer service. |
