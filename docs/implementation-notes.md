# ConfidentialStock: implementation notes (for code review)

Branch: `feat/confidential-stock`. Contract: `src/ConfidentialStock.sol`. Tests: `test/ConfidentialStock.t.sol` (26 tests,
all passing with `forge test`, mock FHEVM via `forge-fhevm`). Specs: `SPEC.md`, then amended by `spec-change-rwa.md` and
`spec-change-disclosure.md` (the latter replaces the "Register access" section of `SPEC.md`).

Status: Solidity is complete. Not yet done: Sepolia deploy script, `demo/demo.ts` (Zama SDK), presentation material.

## What it is
A confidential tokenized stock an issuer can operate: ERC7984 encrypted balances, rebase-style corporate actions with zero
FHE ops, standing register access for customer service, and on-request regulator disclosure.

Dependencies (already in `foundry.toml`): OZ confidential contracts v0.4.0 (git), `@fhevm/solidity` 0.11.1 (OZ pins the same
version, verified), forge-fhevm `eba2324`. OZ code is not modified.

## Design

### Base: `ERC7984Rwa`
- Brings AccessControl, pause, freeze, block/allow lists, agent force-transfer, Multicall. We inherit it instead of
  `ERC7984` + our own AccessControl.
- The issuer is the Rwa **agent** (`AGENT_ROLE`). The constructor's `admin` gets `DEFAULT_ADMIN_ROLE` (manages agents via
  `addAgent`/`removeAgent`) and is also granted `AGENT_ROLE`.
- Only ONE Rwa feature is tested (agent force-transfer). The rest (pause, freeze, blocklist) is inherited and untested by us.

### Issuance
- `mint(uint64 rawAmount)`: agent-only, mints to the immutable `treasury` only, via `_mint(treasury, FHE.asEuint64(raw))`.
  Updates plaintext `rawTotalSupply` (checked `uint64 +=`, so overflow reverts before the encrypted mint).
- Distribution is an ordinary confidential transfer from the treasury.
- **No burn** (descoped).
- Rwa's own `confidentialMint` / `confidentialBurn` (4 overloads) are overridden to revert with `MintBurnDisabled`. Left
  enabled they would mint to arbitrary addresses and burn, desyncing `rawTotalSupply` and breaking the treasury-only rule.

### Balances, multiplier, supply
- Encrypted balances hold RAW shares, 6 decimals (1 share = 1e6 raw). Display = `raw * multiplier / 1e18`, client-side only.
  The contract never multiplies encrypted values.
- `publishedSupply() = rawTotalSupply * multiplier / 1e18`, rounds down (daily CMC/CG publication).

### Corporate actions
- `applyCorporateAction(numerator, denominator, kind)`, agent-only: `multiplier = multiplier * numerator / denominator`.
  Emits `CorporateAction(kind, numerator, denominator, newMultiplier)`. 2-for-1: (2, 1). $0.50 reinvested on $100: (1005, 1000).
- Rounding decision: the multiplier rounds DOWN (1e18 precision). Displayed balances round down client-side.
- Guards (`InvalidCorporateAction`): zero numerator/denominator; new multiplier of 0; new multiplier above `uint192.max`
  (keeps `rawTotalSupply * multiplier` inside uint256 so `publishedSupply()` cannot overflow).
- One multiplier means one uniform rate for all holders (no per-holder withholding). Noted in NatSpec.

### Register access (per `spec-change-disclosure.md`)
Why no jurisdiction mappings: there is no identity registry, and a public `jurisdictionOf` would publish each holder's
nationality on-chain. The customer's need is "regulators on request", so access is on-demand, not standing.
- **Registrar (standing)**: `registrar` address, `setRegistrar` is admin-only, emits `RegistrarSet`. After every update the
  registrar is granted the transferred handle and the new balance handle of each non-zero `from`/`to`.
- **Regulator (on request)**: `disclose(holder, regulator)`, agent-only. Grants `FHE.allow` on the holder's CURRENT balance
  handle, reverts `NothingToDisclose` if the balance is uninitialized, emits `Disclosed(holder, regulator, handle)`.
  Snapshot semantics: later balance changes make a new handle that the regulator cannot decrypt. Historical transfer amounts
  are shared off-chain by the registrar.
- Verified in ERC7984 source: `_update` calls `FHE.allowThis` on every new balance handle, so the token can `allow` it onward.

### Composition with Rwa (the subtle part, please review closely)
- **Force transfer zero endpoints (review P1, fixed):** Rwa's force path skips `_transfer`'s address checks and `_update`
  reads a zero `from`/`to` as mint/burn, so an agent could mint to anyone or burn without updating `rawTotalSupply`.
  `_forceUpdate` now reverts with `ERC7984InvalidSender` / `ERC7984InvalidReceiver` on zero endpoints.
- `_update` override calls `super._update` FIRST, then grants on the handle it RETURNS (Rwa/Freezable can reduce the amount,
  e.g. frozen funds) and on balances read AFTER the update.
- `ERC7984Rwa._forceUpdate` calls `super._update` from inside Rwa, which resolves PAST our override (we sit below Rwa in
  the linearization). So we also override `_forceUpdate` and call the same `_grantRegistrar`. Found by writing the force-transfer
  test first: it failed with `UserNotAuthorizedForDecrypt` until the override was added.
- Both paths share `_grantRegistrar(from, to, transferred)`. Rwa's `_forceUpdate` calls Freezable's `_update`, not ours, so
  there is no double grant.

## Decisions log
| Decision | Why |
|---|---|
| Drop `burn` | Out of MVP scope; also removes a supply-desync risk (encrypted burn silently burns 0 if treasury is short). |
| Build on ERC7984Rwa (spec change) | Gets agent roles, pause/freeze/force-transfer from audited OZ code instead of building them. |
| Disable Rwa mint/burn | Preserves treasury-only issuance and `rawTotalSupply` correctness. |
| Keep plaintext `mint(uint64)` | Rwa mint takes encrypted amounts; primary issuance matches custodian shares, which are public anyway. |
| Treasury as constructor immutable | Smallest surface. No setter. |
| Multiplier rounds down, bounded to `uint192` | Holders never see more than they own; `publishedSupply()` cannot overflow. |
| Keep raw precision at 6 decimals | Finer raw would desync `decimals()` from raw scale for wallets/custodians and shrink the supply cap. |
| Replace jurisdiction/regulator mappings with `disclose` | Avoid publishing nationality on-chain; matches "on request". |
| Single registrar/regulator addresses, no access-holder contract | ACL grants are irrevocable anyway; a contract adds a hop and a trust point. A Safe/multisig as registrar gives rotation without contract changes. |
| Dropped a proposed `syncAccess` | Superseded by `disclose`. |
| Keep `Disclosed` event | Public audit trail for the demo (also leaks that a regulator is looking at an address; open question). |

## Known limitations (intended)
- **ACL grants are not revocable.** Changing the registrar affects future handles only; the old registrar and any disclosed
  regulator keep access to handles already granted.
- **`disclose` is broad (TODO, may revisit):** any agent can expose any holder's current balance to any address. A
  compromised agent key could disclose every balance. Options: separate role, holder-consent flow.
- **`Disclosed` event** is public; signals regulator interest in an address. Open design question.
- **Display resolution after splits:** raw is fixed at 6 decimals, so the smallest tradable unit is `multiplier * 1e-6` shares
  (exactly 1e-6 only at multiplier 1.0; coarser after splits, finer after reverse splits). Clients must convert display to
  raw with floor and send "everything" using the raw balance. Covered by `test_resolutionCoarsensAfterSplit`.
- **Transfer-and-call final amount (review P2, deferred):** `_transferAndCall` (not `virtual` in OZ 0.4.0) returns
  `FHE.sub(sent, refund)`, a new handle the registrar is not granted. The registrar still holds the `sent` and `refund`
  handles and the updated balances, so it can reconstruct the net amount, and balances/supply are unaffected. Ordinary
  `confidentialTransfer` is not affected. Fix would be to grant the registrar in the public transfer-and-call entry points
  (all overloads). Deferred because transfer-and-call is not part of the demo.
- **Silent failure:** an over-balance transfer moves 0 and does not revert (ERC7984 behavior). Callers cannot tell without
  decrypting the result.
- **Uniform multiplier:** one rate for all holders.
- **Supply cap:** `euint64` at 6 decimals caps raw supply at about 18.4T shares.
- **Registrar cost:** up to 3 extra ACL grants per transfer.
- Not built: wrapper/unwrapper, USDC dividends, KYC/identity registry, exchange integration, KYT, Safe/Fireblocks, UI.
- Not done from specs: `ERC7984ObserverAccess` (optional) and the hook-module refactor (stretch; no `ERC7984Hooked` exists in
  the installed OZ v0.4.0).

## Tests (26)
- Issuance: mint to treasury and supply, distribution to Alice/Bob, non-agent mint reverts, mint overflow reverts,
  over-balance transfer moves 0, Rwa mint/burn disabled.
- Rwa: agent force-transfer works, non-agent force-transfer reverts, force transfer rejects zero `from`/`to` (both
  overloads; see review P1).
- Corporate actions: 2-for-1 split, 1005/1000 dividend with rounding, compounding, odd-ratio rounding, non-agent reverts,
  bad inputs revert.
- Fractional shares: exact scaling (1.5 x 1.005), resolution coarsening after a 3-for-1.
- Register access: holder isolation, registrar decrypts balances and transfer amount, admin-only `setRegistrar`,
  `disclose` grants one holder only, non-agent `disclose` reverts, `disclose` with no balance reverts, disclosure is a
  snapshot, force-transfer still grants the registrar.
- Test-harness note: a reverted decrypt in the mock swallows recorded logs and rolls back the plaintext DB update. The helper
  `_assertCannotDecrypt` calls `_processNewLogs()` first. Use it instead of a bare `expectRevert`.

## Suggested review focus
1. `_update` / `_forceUpdate` composition with Rwa (linearization, `override` lists, grants on returned handles and
   post-update balances, no missing or duplicate ACL grants).
2. ACL correctness on every new handle: `allowThis` + holder (OZ) and registrar (ours); anything else that should be granted.
3. Mint/burn invariants: is there any path that changes supply without `rawTotalSupply`? (Rwa mint/burn disabled; check
   `forceConfidentialTransferFrom`, `confidentialTransferAndCall` refund path, and `_update` with `to == address(0)` via other entry points.)
4. Multiplier arithmetic and bounds; `publishedSupply()` overflow.
5. Access control: agent vs admin boundaries, `setRegistrar`, `disclose`, and whether inherited Rwa agent powers
   (pause, freeze, block, force transfer) interact badly with registrar access.
6. Test gaps, especially around pause, frozen balances reducing the transferred handle, and the registrar being unset.

## Repo state
- Commits on `feat/confidential-stock`: Rwa base + mint, corporate actions + fractional tests, registrar + disclosure.
- Uncommitted and not part of the code: `remappings.txt` (reordered line from `forge soldeer install`), `SPEC.md`,
  `TRIAL-BRIEF.md`, `spec-change-*.md`, `docs/`.
- The FHECounter example was removed.
