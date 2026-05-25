
# Polymarket Polygon Dependencies

PSI Finance's `PsiStakingVault` takes 6 external Polymarket addresses at initialization (`ctf`, `negRiskAdapter`, `negRiskCtfExchange`, `ctfExchange`, `underlyingUsdc`, `polymarketWcol`). This document records:

1. The exact addresses to use, and why.
2. Where they came from.
3. The V1 vs V2 / USDC.e vs pUSD decision and its consequences.

All values below are mirrored in `.env.example`.

---

## Authoritative source

Robin Markets' actual mainnet deployment is the ground truth, because:

- **The Phage Security audit (`audits/RobinMarkets-PhageSecurity-Feb2026.pdf`) reviewed Robin's code against the exact contracts Robin was integrating with.** Switching to different Polymarket contracts is a real protocol-semantic change that voids the relevant portions of that audit.
- The transactions in `broadcast/DeployRobinStakingVault.s.sol/137/run-1776211857782.json` are real on-chain executions on Polygon mainnet. They worked. They prove the contracts are deployed and the ABI matches Robin's expectations.

Extraction method: decoded the `InitParams` calldata passed to `ERC1967Proxy(0xcb74449...)` in the broadcast file (first CALL to the vault proxy).

---

## Addresses (mainnet, chain 137)

| Field | Address | Notes |
|---|---|---|
| `ctf` | `0x4d97dcd97ec945f40cf65f87097ace5ea0476045` | Conditional Tokens Framework. Agrees with Polymarket official docs. |
| `negRiskAdapter` | `0xd91e80cf2e7be2e162c6513ced06f1dd0da35296` | Agrees with Polymarket official docs. |
| `ctfExchange` | `0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e` | **Diverges** from Polymarket V2 docs (`0xe111180000d2663c0091e4f400237545b87b996b`). See "V1 vs V2" below. |
| `negRiskCtfExchange` | `0xc5d563a36ae78145c45a50134d48a1215220f80a` | **Diverges** from Polymarket V2 docs (`0xe2222d279d744050d28e00520010520000310f59`). See "V1 vs V2" below. |
| `underlyingUsdc` | `0x2791bca1f2de4661ed88a30c99a7a9449aa84174` | **USDC.e** (bridged USDC). **Diverges** from Polymarket's current `pUSD` collateral (`0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb`). See "USDC.e vs pUSD" below. |
| `polymarketWcol` | `0x3a3bd7bb9528e159577f7c2e685cc81a765002e2` | Wrapped collateral. Not documented in Polymarket's public contracts page; address sourced from Robin's deployment only. |

---

## V1 vs V2 exchange contracts

Polymarket's [official contracts page](https://docs.polymarket.com/resources/contracts) lists:

- CTF Exchange: `0xe111180000d2663c0091e4f400237545b87b996b`
- Neg Risk CTF Exchange: `0xe2222d279d744050d28e00520010520000310f59`

Robin uses different addresses (the table above). The most plausible explanation: Polymarket migrated to a new exchange contract generation at some point, and the V2 contracts are the recommended current ones, but Robin was built against and audited against the previous generation.

**Decision: use Robin's V1 addresses for PSI's initial mainnet deployment.** Rationale:

- PSI's source code (forked from Robin) targets the V1 ABI / event signatures / order matching semantics. Pointing it at V2 contracts could fail at the ABI layer, succeed at the ABI layer but emit different events the indexer doesn't recognize, or silently mis-match fee/refund logic.
- Phage Security's audit assumed V1 integration. Switching invalidates that part of the audit.
- Migrating to V2 should be a deliberate later project — read V2 ABI/events, diff against V1, plan storage/integration migration, re-audit.

If anyone changes these addresses in `.env`, they should know they are deviating from the audited integration.

---

## USDC.e vs pUSD

Polymarket's current docs list pUSD (`0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb`) as the platform collateral. Robin deployed against USDC.e (`0x2791bca1f2de4661ed88a30c99a7a9449aa84174`).

This is consistent with the V1 vs V2 picture: Polymarket's V1 exchanges almost certainly used USDC.e (bridged USDC was the dominant Polygon dollar at the time the V1 contracts were deployed). pUSD appears to be a newer collateral, possibly only used by V2 exchanges.

**Decision: USDC.e** (matches Robin's V1 integration). Switching collateral without switching exchange contracts (or vice versa) would cause approval/transfer mismatches at runtime.

---

## protocolFeeBps — non-obvious choice

Robin deployed with `protocolFeeBps = 0` on mainnet. `implementation.md` suggested a default of `100` (1%). `.env.example` follows Robin and defaults to `0`. This is a business-policy decision, not a technical one — set deliberately based on PSI's fee model.

---

## Pre-deploy verification checklist

Before broadcasting `DeployPsiFinance.s.sol` to Polygon mainnet:

1. Confirm each address in `.env` matches this document exactly (zero typos, lowercase OK).
2. Run a fork test against `$POLYGON_RPC_URL` that actually calls `ctfExchange.fillOrder(...)` and `negRiskCtfExchange.fillOrder(...)` with a small position — proves ABI compatibility, not just that the address is reachable.
3. Read the `audits/RobinMarkets-PhageSecurity-Feb2026.pdf` findings sections that name specific Polymarket contracts. If any finding hinges on V1 semantics and PSI changes them, that finding's mitigation may not apply.
4. If `PSI_OWNER` is a multisig: simulate the post-deploy `setUri` / `setPauseAll` / `addVault` calls through the multisig before deploying to mainnet.
5. If swapping any V1→V2 address: stop. This is a separate workstream, not a config tweak.
