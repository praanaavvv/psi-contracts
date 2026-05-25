# PSI Finance Implementation Plan

## Goal

Build **PSI Finance** by forking Robin Markets' public staking vault contracts, rebranding the contract suite from `Robin*` to `Psi*`, deploying the same vault architecture on **Polygon mainnet**, then building a backend and frontend that use the deployed PSI contracts.

This document is written for **Claude Code**. Follow it as an implementation checklist, not as a vague product brief.

---

## Source Materials

Use these as the source of truth before coding:

- Robin Markets app/site: `https://robin.markets/`
- Robin Markets GitHub org: `https://github.com/robin-markets`
- Main contracts repo: `https://github.com/robin-markets/staking-vault-contracts`
- Robin smart contract docs: `https://robin-markets.gitbook.io/robin-markets-docs/smart-contracts`
- Polymarket contract docs: `https://docs.polymarket.com/resources/contracts`
- Polymarket CTF docs: `https://docs.polymarket.com/trading/ctf/overview`
- Polymarket neg-risk docs: `https://docs.polymarket.com/advanced/neg-risk`



---

## Confirmed Source Repo Facts

The public Robin GitHub organization currently exposes one main Solidity repo:

```txt
robin-markets/staking-vault-contracts
Description: Main Robin vault contracts for staking Polymarket outcome tokens
Language: Solidity
Framework: Foundry
Network config: Polygon chain ID 137
Solidity version: 0.8.31
```

Core contracts found in `src/`:

```txt
src/RobinStakingVault.sol
src/RobinStakingVaultExtension.sol
src/RobinTwapOracle.sol
src/RobinTimeLockController.sol
src/RobinLens.sol
```

Core folders:

```txt
src/interfaces/
src/libraries/
src/mixins/
src/types/
audits/
broadcast/DeployRobinStakingVault.s.sol/137/
lib/
licenses/
```

Foundry config details from `foundry.toml`:

```toml
solc_version = "0.8.31"
src = "src"
out = "out"
libs = ["lib"]
build_info = true
ast = true
extra_output = ["storageLayout"]
extra_output_files = ["metadata"]
optimizer = true
optimizer_runs = 1
ffi = true

[rpc_endpoints]
polygon = "${POLYGON_RPC_URL}"

[etherscan]
polygon = { key = "${ETHERSCAN_API_KEY}", chain = 137 }
```

The Robin vault architecture is not a simple staking contract. It is a multi-contract, upgradeable vault system that interacts with Polymarket CTF outcome tokens, external ERC-4626 yield vaults, TWAP pricing, EIP-712 signatures, and role-based governance.

---

## High-Level Architecture

PSI Finance should have these layers:

```txt
contracts/
  PSI fork of Robin staking vault contracts
  Deploy scripts
  ABI/address export
  Verification scripts
  Tests

backend/
  API server
  Indexer
  Polymarket market sync
  TWAP signer service
  Signed withdrawal executor
  Contract event worker
  Referral/off-chain analytics
  Admin endpoints

frontend/
  Wallet connect
  Market list
  Deposit flow
  Withdraw flow
  Portfolio page
  Signed withdrawal / limit order UX
  Admin panel
```

---

## Phase 0 — Clone And Audit The Source

### Tasks

1. Clone Robin contracts repo.

```bash
git clone https://github.com/robin-markets/staking-vault-contracts.git psi-finance-contracts
cd psi-finance-contracts
git submodule update --init --recursive
```

2. Install Foundry if missing.

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

3. Run baseline build.

```bash
forge clean
forge build
```

4. Run baseline tests if tests exist.

```bash
forge test -vvv
```

5. Inspect license headers.

```bash
grep -R "SPDX-License-Identifier" -n src
```

6. Document all upstream files changed by PSI in `docs/FORK_CHANGES.md`.

### Acceptance Criteria

- Repo builds before rebranding.
- All source contract files have their licenses preserved.
- `docs/FORK_CHANGES.md` exists and lists the fork origin, commit hash, and PSI changes.

---

## Phase 1 — Rebrand Contracts From Robin To PSI

### Rule

Do not only rename filenames. Rename contract names, interface names, EIP-712 domain strings, metadata URI, events/interfaces only where safe, deployment scripts, generated ABIs, frontend references, backend references, and docs.

### Contract Rename Map

```txt
RobinStakingVault.sol             -> PsiStakingVault.sol
RobinStakingVaultExtension.sol    -> PsiStakingVaultExtension.sol
RobinTwapOracle.sol               -> PsiTwapOracle.sol
RobinTimeLockController.sol       -> PsiTimeLockController.sol
RobinLens.sol                     -> PsiLens.sol
```

### Interface Rename Map

Apply this pattern across `src/interfaces`:

```txt
IRobinStakingVault                -> IPsiStakingVault
IRobinTwapOracle                  -> IPsiTwapOracle
IRobinLens                        -> IPsiLens
IRobinAccountingView              -> IPsiAccountingView
IRobinPolymarketView              -> IPsiPolymarketView
IRobinYieldStrategyView           -> IPsiYieldStrategyView
IRobinSignaturesView              -> IPsiSignaturesView
IRobinPausableView                -> IPsiPausableView
IRobinStakingVaultErrors          -> IPsiStakingVaultErrors
IRobinStakingVaultEvents          -> IPsiStakingVaultEvents
```

### Internal Storage Names

Be careful with ERC-7201 storage slots.

Search for storage namespace strings like:

```txt
robin.storage.*
```

Decision:

- For a clean fresh PSI deployment, rename namespaces to `psi.storage.*`.
- For upgrades to any existing Robin deployment, never rename storage namespaces.
- Since PSI is a new deployment, rename namespaces only if tests pass and storage layout remains internally consistent.

### EIP-712 Names

Update:

```txt
RobinStakingVault -> PsiStakingVault
RobinTwapOracle   -> PsiTwapOracle
```

In `PsiStakingVault.initialize`, update the signatures mixin call from:

```solidity
__SignaturesMixin_init("RobinStakingVault", "1", params.ctfExchange);
```

to:

```solidity
__SignaturesMixin_init("PsiStakingVault", "1", params.ctfExchange);
```

In `PsiTwapOracle.initialize`, use:

```txt
name = "PsiTwapOracle"
version = "1"
```

### Metadata URI

Change the default ERC-1155 metadata URI from Robin API to PSI API.

Original pattern:

```txt
https://api.robin.markets/v1/shares/{id}
```

New pattern:

```txt
https://api.psi.finance/v1/shares/{id}
```

If the production API domain is not ready, use env-configured deployment value and default to:

```txt
https://api-dev.psi.finance/v1/shares/{id}
```

### Acceptance Criteria

- `grep -R "Robin" src script test` returns no Robin references unless inside preserved license/source attribution docs.
- `forge build` passes.
- Contract bytecode remains under EIP-170 size limits.
- UUPS storage layout is reviewed after the rename.
- Generated ABI names are PSI-prefixed.

---

## Phase 2 — Polygon Dependency Configuration

Robin contracts integrate with Polymarket outcome tokens. PSI should deploy on **Polygon mainnet** and connect to the correct Polymarket contracts.

### Current Polymarket Polygon Addresses To Verify Before Deployment

Use Polymarket's official contracts page immediately before production deployment. As of the current docs snapshot:

```txt
Polygon chain ID: 137

Conditional Tokens / CTF:
0x4D97DCd97eC945f40cF65F87097ACe5EA0476045

CTF Exchange V2:
0xE111180000d2663C0091e4f400237545B87B996B

Neg Risk CTF Exchange:
0xe2222d279d744050d28e00520010520000310F59

Neg Risk Adapter:
0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296

pUSD CollateralToken proxy:
0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB
```

Robin code uses these init fields:

```solidity
struct InitParams {
    address owner;
    address timelockController;
    uint256 protocolFeeBps;
    address ctf;
    address negRiskAdapter;
    address negRiskCtfExchange;
    address ctfExchange;
    address underlyingUsdc;
    address polymarketWcol;
    address twapOracle;
    address extension;
}
```

### Important Dependency Decision

Before deploying, determine whether `underlyingUsdc` should be:

1. Current Polymarket `pUSD` collateral token, or
2. Older bridged `USDC.e`, or
3. Another collateral wrapper expected by the Robin repo.

Do not guess. Confirm by reading the current Polymarket docs, Robin deployment broadcast, and the mixins:

```txt
src/mixins/PolymarketMixin.sol
src/mixins/YieldStrategyMixin.sol
src/libraries/*
```

### Environment Variables

Create `.env.example`:

```bash
POLYGON_RPC_URL=
POLYGONSCAN_API_KEY=
DEPLOYER_PRIVATE_KEY=

PSI_OWNER=
PSI_TIMELOCK_MIN_DELAY=86400
PSI_PROTOCOL_FEE_BPS=100

POLYMARKET_CTF=0x4D97DCd97eC945f40cF65F87097ACe5EA0476045
POLYMARKET_CTF_EXCHANGE=0xE111180000d2663C0091e4f400237545B87B996B
POLYMARKET_NEG_RISK_CTF_EXCHANGE=0xe2222d279d744050d28e00520010520000310F59
POLYMARKET_NEG_RISK_ADAPTER=0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296
POLYMARKET_COLLATERAL=
POLYMARKET_WCOL=

PSI_TWAP_SIGNER=
PSI_METADATA_URI=https://api.psi.finance/v1/shares/{id}
```

### Acceptance Criteria

- `.env.example` exists.
- The deployment script reads all addresses from env.
- No hardcoded owner/private key exists.
- Production deployment requires explicit confirmation of collateral addresses.

---

## Phase 3 — Deployment Script

Create:

```txt
script/DeployPsiFinance.s.sol
```

### Deployment Order

Deploy in this order:

1. `PsiTimeLockController`
2. `PsiTwapOracle` implementation
3. `ERC1967Proxy` for `PsiTwapOracle`
4. `PsiStakingVaultExtension`
5. `PsiStakingVault` implementation
6. `ERC1967Proxy` for `PsiStakingVault`
7. `PsiLens`
8. Grant `VAULT_ROLE` on `PsiTwapOracle` to the `PsiStakingVault` proxy
9. Optional: add external ERC-4626 yield vaults
10. Export addresses and ABIs

### Pseudocode

```solidity
contract DeployPsiFinance is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("PSI_OWNER");
        address twapSigner = vm.envAddress("PSI_TWAP_SIGNER");

        vm.startBroadcast(deployerKey);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;

        address[] memory executors = new address[](1);
        executors[0] = owner;

        PsiTimeLockController timelock = new PsiTimeLockController(
            vm.envUint("PSI_TIMELOCK_MIN_DELAY"),
            proposers,
            executors
        );

        PsiTwapOracle oracleImpl = new PsiTwapOracle();

        bytes memory oracleInit = abi.encodeCall(
            PsiTwapOracle.initialize,
            (
                owner,
                address(timelock),
                "PsiTwapOracle",
                "1",
                twapSigner
            )
        );

        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            oracleInit
        );

        PsiStakingVaultExtension extension = new PsiStakingVaultExtension();
        PsiStakingVault vaultImpl = new PsiStakingVault();

        DataTypes.InitParams memory params = DataTypes.InitParams({
            owner: owner,
            timelockController: address(timelock),
            protocolFeeBps: vm.envUint("PSI_PROTOCOL_FEE_BPS"),
            ctf: vm.envAddress("POLYMARKET_CTF"),
            negRiskAdapter: vm.envAddress("POLYMARKET_NEG_RISK_ADAPTER"),
            negRiskCtfExchange: vm.envAddress("POLYMARKET_NEG_RISK_CTF_EXCHANGE"),
            ctfExchange: vm.envAddress("POLYMARKET_CTF_EXCHANGE"),
            underlyingUsdc: vm.envAddress("POLYMARKET_COLLATERAL"),
            polymarketWcol: vm.envAddress("POLYMARKET_WCOL"),
            twapOracle: address(oracleProxy),
            extension: address(extension)
        });

        bytes memory vaultInit = abi.encodeCall(
            PsiStakingVault.initialize,
            (params)
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInit
        );

        PsiLens lens = new PsiLens(address(vaultProxy));

        bytes32 VAULT_ROLE = PsiTwapOracle(address(oracleProxy)).VAULT_ROLE();
        PsiTwapOracle(address(oracleProxy)).grantRole(VAULT_ROLE, address(vaultProxy));

        vm.stopBroadcast();

        // Write deployment json to deployments/polygon/psi-finance.json
    }
}
```

### Deploy Commands

```bash
source .env

forge script script/DeployPsiFinance.s.sol:DeployPsiFinance \
  --rpc-url polygon \
  --broadcast \
  --verify \
  -vvvv
```

If verification fails, verify manually:

```bash
forge verify-contract \
  --chain 137 \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  <CONTRACT_ADDRESS> \
  src/PsiStakingVault.sol:PsiStakingVault
```

### Deployment Output

Create:

```txt
deployments/polygon/psi-finance.json
```

Expected shape:

```json
{
  "chainId": 137,
  "network": "polygon",
  "deployedAt": "ISO_DATE",
  "contracts": {
    "PsiTimeLockController": "0x...",
    "PsiTwapOracleImplementation": "0x...",
    "PsiTwapOracleProxy": "0x...",
    "PsiStakingVaultExtension": "0x...",
    "PsiStakingVaultImplementation": "0x...",
    "PsiStakingVaultProxy": "0x...",
    "PsiLens": "0x..."
  },
  "dependencies": {
    "ctf": "0x...",
    "ctfExchange": "0x...",
    "negRiskCtfExchange": "0x...",
    "negRiskAdapter": "0x...",
    "collateral": "0x...",
    "wcol": "0x..."
  }
}
```

### Acceptance Criteria

- Deployment succeeds on a Polygon fork first.
- Deployment succeeds on Polygon mainnet.
- Contract source is verified on Polygonscan.
- `VAULT_ROLE` is granted to the vault proxy on the oracle.
- Owner, manager, pauser, fee harvester, and external vault manager roles are correct.
- No role remains assigned to the deployer unless deployer is intended owner.

---

## Phase 4 — Contract Test Plan

### Fork Tests

Create fork tests against Polygon:

```txt
test/fork/PsiDeploymentFork.t.sol
test/fork/PsiPolymarketIntegrationFork.t.sol
test/fork/PsiOracleFork.t.sol
```

### Required Tests

1. Deployment initializes all contracts.
2. Vault proxy points to implementation.
3. Oracle proxy points to implementation.
4. Vault role is granted on oracle.
5. Owner has:
   - `DEFAULT_ADMIN_ROLE`
   - `DEFAULT_MANAGER_ROLE`
   - `FEE_HARVESTER_ROLE`
   - `PAUSER_ROLE`
   - `EXTERNAL_VAULT_MANAGER_ROLE`
6. Timelock has:
   - `TIMELOCKED_ROLE`
7. `deposit` reverts when no approval.
8. `deposit` works after ERC-1155 approval if test account owns outcome tokens.
9. `withdraw` burns shares and returns outcome tokens.
10. `executeSignedWithdrawal` consumes nonce and prevents replay.
11. `pauseDeposits` blocks deposits.
12. `pauseWithdrawals` blocks withdrawals.
13. `PsiLens` batch reads portfolio correctly.
14. TWAP submit:
   - accepts valid signed batch
   - rejects invalid signer
   - handles finalized market
15. Emergency mode withdraws from external vaults.

### Commands

```bash
forge test -vvv
forge test --fork-url $POLYGON_RPC_URL -vvv
forge coverage
```

### Acceptance Criteria

- All tests pass locally.
- Fork test covers at least one real Polymarket condition ID.
- Signed TWAP and signed withdrawal flows are tested end-to-end.

---

## Phase 5 — Backend Implementation

### Recommended Stack

Use one of these:

```txt
Option A: Node.js + TypeScript + Fastify/NestJS + Viem + PostgreSQL + Redis
Option B: Node.js + TypeScript + Express + Viem + PostgreSQL + BullMQ
```

Use `viem` over `ethers` for new TypeScript code unless the existing frontend already depends heavily on ethers.

### Backend Responsibilities

The backend must not custody user funds. Its job is:

1. Read Polymarket markets.
2. Store markets, condition IDs, token IDs, and neg-risk flags.
3. Read PSI vault state.
4. Serve frontend portfolio data.
5. Sign TWAP batches using `PSI_TWAP_SIGNER`.
6. Execute signed withdrawals only when user-signed limits are met.
7. Index contract events.
8. Serve ERC-1155 metadata for PSI shares.
9. Track referrals off-chain.
10. Provide admin APIs for operational actions.

### Backend Folder Structure

```txt
backend/
  src/
    config/
      env.ts
      chains.ts
      contracts.ts
    abi/
      PsiStakingVault.json
      PsiTwapOracle.json
      PsiLens.json
      ERC1155.json
      ERC20.json
    db/
      schema.sql
      migrations/
      client.ts
    modules/
      markets/
        markets.service.ts
        polymarket.client.ts
        gamma.client.ts
      vault/
        vault.reader.ts
        vault.writer.ts
        vault.events.ts
      oracle/
        twap.service.ts
        twap.signer.ts
        twap.worker.ts
      withdrawals/
        signed-withdrawal.service.ts
        executor.worker.ts
      portfolio/
        portfolio.service.ts
      metadata/
        share-metadata.controller.ts
      admin/
        admin.controller.ts
        admin.service.ts
    workers/
      indexer.worker.ts
      twap.worker.ts
      withdrawal-executor.worker.ts
    server.ts
  package.json
  .env.example
```

### Database Tables

Create PostgreSQL schema:

```sql
create table markets (
  id bigserial primary key,
  condition_id text unique not null,
  question text,
  slug text,
  icon text,
  end_date timestamptz,
  neg_risk boolean not null default false,
  yes_token_id text,
  no_token_id text,
  active boolean not null default true,
  closed boolean not null default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table contract_deployments (
  id bigserial primary key,
  chain_id integer not null,
  name text not null,
  address text not null,
  abi jsonb,
  created_at timestamptz default now(),
  unique(chain_id, name)
);

create table vault_events (
  id bigserial primary key,
  chain_id integer not null,
  tx_hash text not null,
  log_index integer not null,
  block_number bigint not null,
  event_name text not null,
  user_address text,
  condition_id text,
  payload jsonb not null,
  created_at timestamptz default now(),
  unique(chain_id, tx_hash, log_index)
);

create table user_positions (
  id bigserial primary key,
  chain_id integer not null,
  user_address text not null,
  condition_id text not null,
  yes_shares numeric not null default 0,
  no_shares numeric not null default 0,
  yes_assets numeric not null default 0,
  no_assets numeric not null default 0,
  yes_yield numeric not null default 0,
  no_yield numeric not null default 0,
  updated_at timestamptz default now(),
  unique(chain_id, user_address, condition_id)
);

create table twap_updates (
  id bigserial primary key,
  condition_id text not null,
  start_timestamp bigint not null,
  end_timestamp bigint not null,
  twap_price_yes numeric not null,
  market_ended_at bigint not null default 0,
  market_end_yes_price numeric not null default 0,
  signature text not null,
  submitted_tx_hash text,
  created_at timestamptz default now()
);

create table signed_withdrawal_orders (
  id bigserial primary key,
  user_address text not null,
  signer_address text not null,
  condition_id text not null,
  yes_shares numeric not null default 0,
  no_shares numeric not null default 0,
  min_yes_tokens numeric not null default 0,
  min_no_tokens numeric not null default 0,
  yield_recipient text,
  protect_against_loss boolean not null default true,
  nonce numeric not null,
  expiry bigint not null,
  signature_type integer not null,
  signature text not null,
  status text not null default 'open',
  execution_tx_hash text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(user_address, nonce)
);

create table referrals (
  id bigserial primary key,
  referral_code numeric unique not null,
  owner_address text not null,
  created_at timestamptz default now()
);
```

### API Endpoints

```txt
GET  /health
GET  /config
GET  /markets
GET  /markets/:conditionId
GET  /portfolio/:address
GET  /portfolio/:address/:conditionId
GET  /metadata/shares/:id

POST /twap/submit
POST /withdrawals/signed
POST /withdrawals/:id/cancel

GET  /admin/deployments
POST /admin/vaults/add
POST /admin/vaults/:address/cap
POST /admin/vaults/:address/active
POST /admin/pause
POST /admin/oracle/global-required
POST /admin/oracle/global-disabled
```

### Contract Reads

Use these read functions:

```txt
PsiStakingVault.getUserShares(user, conditionId)
PsiStakingVault.getUserAssets(user, conditionId)
PsiStakingVault.getUserYield(user, conditionId, twapPriceYes)
PsiStakingVault.previewDeposit(conditionId, side, amount)
PsiStakingVault.previewWithdraw(user, conditionId, side, shares, twapPriceYes)
PsiStakingVault.getMarketState(conditionId)
PsiStakingVault.getPolymarketTokenInfo(conditionId)
PsiStakingVault.getUnpairedTokens(conditionId)
PsiStakingVault.getExternalVaults()
PsiTwapOracle.getMarketState(conditionId)
PsiTwapOracle.isTwapSignatureRequired(conditionId)
PsiLens.batchGetUserPortfolio(...)
PsiLens.checkBatchDepositCapacity(...)
```

### Contract Writes

Frontend/user wallet writes:

```txt
CTF.setApprovalForAll(PsiStakingVaultProxy, true)
PsiStakingVault.deposit(conditionId, yesAmount, noAmount, referralCode)
PsiStakingVault.batchDeposit(conditionIds, yesAmounts, noAmounts, nonZeroLength, referralCode)
PsiStakingVault.withdraw(conditionId, yesShares, noShares, yieldRecipient, referralCode)
PsiStakingVault.batchWithdraw(conditionIds, yesShares, noShares, yieldRecipient, nonZeroLength, referralCode)
PsiStakingVault.invalidateNonces(nonces)
PsiStakingVault.invalidateNonceWord(wordPos)
```

Backend writes:

```txt
PsiStakingVault.initializeMarket(conditionId)
PsiTwapOracle.submitTwap(batchTwapData)
PsiStakingVault.executeSignedWithdrawal(signedWithdrawal)
```

Admin writes:

```txt
PsiStakingVault.addVault(vault, cap)
PsiStakingVault.removeVault(vault)
PsiStakingVault.setVaultCap(vault, cap)
PsiStakingVault.setVaultActive(vault, active)
PsiStakingVault.supplyIdleToVaults()
PsiStakingVault.setPauseAll(paused)
PsiStakingVault.setPauseDeposits(paused)
PsiStakingVault.setPauseWithdrawals(paused)
PsiStakingVault.setPauseTransfers(paused)
PsiStakingVault.harvestProtocolFee(to)
PsiStakingVault.setUri(newUri)
```

### TWAP Service

Implement a service that:

1. Pulls current Polymarket prices/orderbook/trades.
2. Computes TWAP for each active `conditionId`.
3. Creates `DataTypes.TwapData`.
4. Signs `BatchTwapData` with `PSI_TWAP_SIGNER`.
5. Stores signed batch in DB.
6. Submits `submitTwap` when required or before withdrawals.

TWAP data shape:

```ts
type TwapData = {
  required: boolean;
  conditionId: `0x${string}`;
  startTimestamp: bigint;
  endTimestamp: bigint;
  twapPriceYes: bigint; // 0 to 1e6
  marketEndedAt: bigint;
  marketEndYesPrice: bigint; // 0 to 1e6
};
```

Price scale:

```txt
1e6 = 100%
500000 = 50%
1000000 = YES settled to $1
0 = YES settled to $0
```

### Signed Withdrawal Executor

Implement worker:

```txt
workers/withdrawal-executor.worker.ts
```

Logic:

1. Poll open signed withdrawal orders.
2. Ignore expired orders.
3. Check latest market price and vault preview.
4. If price reaches user limit:
   - submit latest TWAP first if required
   - call `executeSignedWithdrawal`
   - update DB status to `executed`
5. If transaction reverts due to nonce/signature/loss protection:
   - mark `failed`
   - save revert reason

### Backend Acceptance Criteria

- Backend starts with `pnpm dev`.
- Backend can read deployed contract addresses from `deployments/polygon/psi-finance.json`.
- Portfolio endpoint works for any wallet.
- TWAP signer produces signatures accepted by `PsiTwapOracle`.
- Event indexer backfills from deployment block to latest.
- Signed withdrawal executor handles replay, expiry, and loss protection.
- No private key is logged.
- Admin endpoints require authentication.

---

## Phase 6 — Frontend Integration

### Recommended Stack

Use the existing frontend if available. If starting fresh:

```txt
Next.js
TypeScript
wagmi
viem
RainbowKit or Privy
TanStack Query
TailwindCSS
```

### Frontend Folder Structure

```txt
frontend/
  src/
    app/
    components/
      market/
      portfolio/
      deposit/
      withdraw/
      wallet/
      admin/
    config/
      contracts.ts
      chains.ts
    hooks/
      useMarkets.ts
      usePortfolio.ts
      useDeposit.ts
      useWithdraw.ts
      useApproval.ts
    lib/
      abi/
      api.ts
      format.ts
      units.ts
```

### Required User Flows

#### 1. Connect Wallet

- Connect Polygon wallet.
- If user is on wrong chain, request switch to Polygon chain ID `137`.

#### 2. Market List

- Fetch from backend `/markets`.
- Show:
  - question
  - end date
  - YES/NO current prices
  - user position if connected
  - capacity status from `PsiLens.checkBatchDepositCapacity`

#### 3. Deposit Flow

Steps:

1. User selects market.
2. User selects YES, NO, or both.
3. Frontend checks ERC-1155 approval:

```ts
CTF.isApprovedForAll(user, PSI_STAKING_VAULT_PROXY)
```

4. If not approved, ask for:

```ts
CTF.setApprovalForAll(PSI_STAKING_VAULT_PROXY, true)
```

5. Preview shares:

```ts
PsiStakingVault.previewDeposit(conditionId, side, amount)
```

6. Submit:

```ts
PsiStakingVault.deposit(conditionId, yesAmount, noAmount, referralCode)
```

7. Refresh portfolio.

#### 4. Withdraw Flow

Steps:

1. User selects PSI shares to burn.
2. Frontend previews:

```ts
PsiStakingVault.previewWithdraw(user, conditionId, side, sharesToBurn, twapPriceYes)
```

3. User submits:

```ts
PsiStakingVault.withdraw(conditionId, yesShares, noShares, yieldRecipient, referralCode)
```

4. Show returned YES/NO tokens and USDC yield.

#### 5. Signed Withdrawal / Limit Order Flow

Steps:

1. User chooses condition, shares, min received, expiry.
2. Frontend signs EIP-712 `SignedWithdrawal`.
3. Frontend posts signed object to backend:

```txt
POST /withdrawals/signed
```

4. Backend monitors and executes.

#### 6. Portfolio Page

Use backend `/portfolio/:address` plus direct reads from `PsiLens` for freshness.

Show:

```txt
Market
YES shares
NO shares
YES assets
NO assets
Yield
Withdraw button
Signed withdrawal button
```

#### 7. Admin Panel

Only for admin wallets.

Features:

```txt
Pause deposits
Pause withdrawals
Pause transfers
Add/remove external vault
Set vault cap
Set vault active
Submit TWAP manually
Harvest protocol fees
Emergency mode
```

### Frontend Acceptance Criteria

- Frontend points to PSI contracts, not Robin contracts.
- No Robin branding remains.
- Wallet approval flow works.
- Deposit and withdraw txs work on Polygon fork/mainnet.
- Portfolio updates after events.
- Admin actions are hidden from non-admin wallets.

---

## Phase 7 — ABI And Address Export

After deployment, generate frontend/backend ABI artifacts.

### Script

Create:

```txt
scripts/export-abis.ts
```

Output:

```txt
packages/contracts/abi/PsiStakingVault.json
packages/contracts/abi/PsiTwapOracle.json
packages/contracts/abi/PsiLens.json
packages/contracts/deployments/polygon.json
```

### Package Shape

```ts
export const polygonDeployments = {
  chainId: 137,
  PsiStakingVault: "0x...",
  PsiTwapOracle: "0x...",
  PsiLens: "0x...",
  PsiTimeLockController: "0x...",
} as const;
```

### Acceptance Criteria

- Backend imports ABI/address from one shared package.
- Frontend imports ABI/address from the same shared package.
- No duplicate hardcoded addresses in frontend/backend.

---

## Phase 8 — Security Checklist

Before mainnet launch:

### Smart Contracts

- Preserve license headers.
- Run Slither.
- Run Mythril or equivalent if possible.
- Review UUPS upgrade roles.
- Review ERC-7201 storage layout.
- Review fallback delegatecall to extension.
- Review all external vault integrations.
- Review oracle signer compromise risk.
- Review TWAP finalization logic.
- Review pause/emergency mode.
- Review signed withdrawal replay protection.
- Review loss protection logic.
- Review approval risks.

### Backend

- Private keys stored in secrets manager.
- TWAP signer isolated from web API server.
- Admin endpoints authenticated.
- Rate limits enabled.
- Event indexer idempotent.
- Withdrawal executor idempotent.
- Reorg handling implemented.
- Every transaction write has retries and nonce management.
- Logs never include private keys or raw secrets.

### Frontend

- Show exact contract address before approval.
- Warn users about unlimited ERC-1155 approval.
- Use chain ID checks.
- Use transaction simulation before writes.
- Clear error messages for revert reasons.
- Block wrong-chain writes.

---

## Phase 9 — Production Deployment Runbook

### Pre-Deploy

```bash
forge clean
forge build
forge test -vvv
forge test --fork-url $POLYGON_RPC_URL -vvv
```

Confirm:

```txt
POLYGON_RPC_URL set
POLYGONSCAN_API_KEY set
DEPLOYER_PRIVATE_KEY set
PSI_OWNER set
PSI_TWAP_SIGNER set
Polymarket addresses verified from official docs
Collateral address confirmed
Timelock delay confirmed
Protocol fee bps confirmed
```

### Deploy

```bash
forge script script/DeployPsiFinance.s.sol:DeployPsiFinance \
  --rpc-url polygon \
  --broadcast \
  --verify \
  -vvvv
```

### Post-Deploy

1. Save deployment JSON.
2. Commit deployment JSON.
3. Export ABIs.
4. Update backend env.
5. Start backend in read-only mode.
6. Backfill events.
7. Start TWAP worker.
8. Start withdrawal executor.
9. Deploy frontend.
10. Run smoke tests.

### Smoke Tests

```txt
GET /health returns ok
GET /config returns Polygon + PSI addresses
GET /markets returns markets
GET /portfolio/:wallet returns empty or positions
Wallet connects on frontend
Approval tx succeeds
Small deposit succeeds
Small withdraw succeeds
TWAP submit succeeds
Admin pause/unpause succeeds
```

---

## Claude Code Execution Prompt

Use this exact prompt in Claude Code from the repo root:

```txt
You are implementing PSI Finance by forking Robin Markets staking vault contracts.

Goal:
Rebrand and deploy Robin's staking-vault-contracts architecture as PSI Finance on Polygon mainnet, then prepare backend and frontend integration.

Source repo:
https://github.com/robin-markets/staking-vault-contracts

Important constraints:
- Preserve license headers and add fork attribution docs.
- Do not remove security controls.
- Do not hardcode private keys or owner addresses.
- Keep Polygon chain ID 137.
- Keep Foundry with Solidity 0.8.31.
- Keep optimizer enabled with optimizer_runs = 1 unless build proves it can change safely.
- Preserve UUPS upgrade safety.
- Review ERC-7201 storage namespaces before renaming.
- Update EIP-712 names from Robin to PSI.
- Update metadata URI from Robin API to PSI API.
- Export ABIs and deployment addresses for backend/frontend.
- Write tests for deployment, roles, oracle, deposit, withdraw, signed withdrawal, pause, emergency, and lens reads.

Implementation tasks:
1. Inspect the full source tree and build the unmodified repo.
2. Create docs/FORK_CHANGES.md with upstream repo URL, commit hash, license note, and PSI modifications.
3. Rename contracts:
   RobinStakingVault -> PsiStakingVault
   RobinStakingVaultExtension -> PsiStakingVaultExtension
   RobinTwapOracle -> PsiTwapOracle
   RobinTimeLockController -> PsiTimeLockController
   RobinLens -> PsiLens
4. Rename interfaces and references from IRobin* to IPsi*.
5. Update EIP-712 domain names:
   RobinStakingVault -> PsiStakingVault
   RobinTwapOracle -> PsiTwapOracle
6. Update metadata URI to env-configurable PSI URI:
   https://api.psi.finance/v1/shares/{id}
7. Create script/DeployPsiFinance.s.sol that deploys:
   PsiTimeLockController
   PsiTwapOracle implementation + ERC1967Proxy
   PsiStakingVaultExtension
   PsiStakingVault implementation + ERC1967Proxy
   PsiLens
   Then grants VAULT_ROLE on oracle to vault proxy.
8. Create .env.example with:
   POLYGON_RPC_URL
   POLYGONSCAN_API_KEY
   DEPLOYER_PRIVATE_KEY
   PSI_OWNER
   PSI_TIMELOCK_MIN_DELAY
   PSI_PROTOCOL_FEE_BPS
   POLYMARKET_CTF
   POLYMARKET_CTF_EXCHANGE
   POLYMARKET_NEG_RISK_CTF_EXCHANGE
   POLYMARKET_NEG_RISK_ADAPTER
   POLYMARKET_COLLATERAL
   POLYMARKET_WCOL
   PSI_TWAP_SIGNER
   PSI_METADATA_URI
9. Create deployments/polygon/psi-finance.example.json.
10. Add export script for ABIs and deployments.
11. Add fork tests for Polygon using POLYGON_RPC_URL.
12. Build a backend skeleton in backend/ using TypeScript, viem, PostgreSQL, and workers:
    markets sync
    vault reader
    event indexer
    TWAP signer
    signed withdrawal executor
    metadata endpoint
    admin endpoints
13. Build or prepare frontend integration hooks:
    useApproval
    useDeposit
    useWithdraw
    usePortfolio
    useSignedWithdrawal
    useAdminVault
14. Ensure grep -R "Robin" src backend frontend returns no Robin product references except attribution/legal docs.
15. Run:
    forge clean
    forge build
    forge test -vvv
    forge test --fork-url $POLYGON_RPC_URL -vvv
16. Produce a final IMPLEMENTATION_REPORT.md containing:
    files changed
    deployment commands
    test results
    unresolved risks
    exact next steps for mainnet deployment

Do not stop after renaming files. Complete deployment scripts, env examples, ABI export, backend skeleton, frontend hooks, and tests.
```

---

## Final Deliverables

Claude Code should produce:

```txt
contracts renamed to PSI
script/DeployPsiFinance.s.sol
.env.example
deployments/polygon/psi-finance.example.json
deployments/polygon/psi-finance.json after deployment
packages/contracts/abi/*.json
packages/contracts/deployments/polygon.json
backend/ skeleton with API + workers
frontend hooks/components wired to PSI contracts
docs/FORK_CHANGES.md
IMPLEMENTATION_REPORT.md
```

---

## Risks / Things Claude Must Not Ignore

2. **Collateral risk**: Polymarket collateral has changed over time. Confirm `underlyingUsdc` and `polymarketWcol` before deployment.
3. **Oracle risk**: TWAP signer controls yield/loss accounting inputs. Protect the signer key.
4. **Upgrade risk**: UUPS upgrades are timelock-controlled. Test upgrade paths before launch.
5. **Delegatecall extension risk**: Main vault fallback delegates to extension. Any storage mismatch can be critical.
6. **External ERC-4626 vault risk**: Bad external vaults can create loss or liquidity issues.
7. **Frontend approval risk**: ERC-1155 approvals are powerful. Show clear UI warnings.
8. **Backend executor risk**: Signed withdrawal execution must be idempotent and replay-safe.
9. **Polymarket dependency risk**: PSI depends on Polymarket CTF/exchange contracts and market data availability.

