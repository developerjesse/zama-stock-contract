# Spec change: build on ERC7984Rwa

Apply to the existing ConfidentialStock work. Do not restart.

## 1. Switch base to ERC7984Rwa (do first)
- Read the installed `ERC7984Rwa.sol` (and `IERC7984Rwa.sol`) before changing anything.
- Find how it manages roles (AccessControl? agent role name?). If it already brings
  AccessControl, remove our own AccessControl inheritance to avoid duplicates.
- Map our existing issuer/minter role onto Rwa's agent role. The issuer is the agent.
- Check Rwa's mint functions. If they only accept encrypted amounts, keep our
  plaintext `mint(uint64 rawAmount)` (agent-only, treasury-only) that calls the
  internal `_mint(treasury, FHE.asEuint64(rawAmount))` and updates `rawTotalSupply`.
- Rwa also gives pause, freeze, allow/blocklist, force transfer. Don't build UI or
  tests for all of them. Add ONE test: agent force-transfer works (lawful order / lost keys).

## 2. Keep register access as an `_update` override
- ERC7984Rwa overrides `_update` too. Make sure our override composes via `super`
  (check the inheritance order and the `override(...)` list compiles).
- Grant registrar/regulator ACL on the handles *after* `super._update` returns the
  final transferred amount and new balances (Rwa may adjust the amount, e.g. frozen balances).
- All existing register-access tests must still pass.

## 3. Optional: ERC7984ObserverAccess
- Only if it's a clean extra inheritance. Holder-driven disclosure: a holder sets
  their own auditor. One test: holder sets observer, observer decrypts holder's balance.

## 4. Stretch (only if 1-3 pass and Sepolia deploy works): register access as a hook module
- Refactor the registrar/regulator grants into an `ERC7984Hooked` module.
- Token must `FHE.allow` the handles to the module before calling it; the module
  then grants to registrar/regulators. Same cross-contract ACL pattern as the
  earlier ComplianceModule work.

## Unchanged
- Public multiplier + `applyCorporateAction` (split, reinvested dividend).
- Mint to treasury, distribute via confidential transfer. No burn.
- Foundry for contracts/tests/deploy; Sepolia interaction via Zama SDK in TypeScript.