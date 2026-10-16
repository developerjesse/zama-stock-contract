# Spec change: register access = standing registrar + on-request regulator disclosure

Apply to the existing ConfidentialStock work, after the ERC7984Rwa switch. Do not restart.
This REPLACES the "Register access" section of SPEC.md.

## Why
- No identity registry exists (no ONCHAINID). A public `jurisdictionOf` mapping would
  publish each holder's nationality on-chain, which defeats the point of a confidential token.
- The customer's ask is "regulators may need to see it **on request**" — on-demand
  disclosure, not standing access on every handle.

## Remove
- `mapping(bytes32 => address) regulatorFor`
- `mapping(address => bytes32) jurisdictionOf`
- Their setters, and any jurisdiction logic in `_update`.
- `REGISTRAR_ADMIN_ROLE` if it only existed for jurisdictions. Setting the registrar
  can use the existing admin role.

## Keep / change

### Registrar (standing access — customer service needs the full register "at all times")
- `address public registrar`; `setRegistrar(address)` admin-only; emit `RegistrarSet(address)`.
- `_update` override (composes with ERC7984Rwa via `super`):
  - Call `super._update(from, to, amount)` FIRST and use the handle it RETURNS
    (Rwa may reduce the amount, e.g. frozen balances). Do not grant on the input handle.
  - If `registrar != address(0)`:
    - `FHE.allow(transferred, registrar)`
    - for each of `from`, `to` that is non-zero: `FHE.allow(confidentialBalanceOf(account), registrar)`
  - Return the transferred handle.
- Comment: changing the registrar only affects future handles; the previous registrar keeps
  access to handles it was already granted (ACL grants are not revocable).

### Regulator disclosure (on request)
- `function disclose(address holder, address regulator) external` — agent-only (Rwa agent role).
  - `euint64 bal = confidentialBalanceOf(holder);`
  - require `FHE.isInitialized(bal)` (revert with a custom error if the holder has no balance).
  - `FHE.allow(bal, regulator);`
  - `emit Disclosed(holder, regulator, euint64.unwrap(bal));`
- Before writing this, VERIFY in the installed ERC7984 source that the token contract holds
  `allowThis` on balance handles. The contract can only `FHE.allow` a handle it has access to.
- Comment: disclosure is a snapshot of the current balance. Future balances need another
  `disclose` call. Historical transfer amounts are shared off-chain by the registrar (who
  holds ACL on all of them) — out of scope for the contract.
- Comment: the `Disclosed` event is a public audit trail but also signals that a regulator is
  looking at an address. Open design question; keep the event for the demo.

## Tests (replace old tests 4–5; keep all others)
4. Registrar decrypts Alice's and Bob's balances and the transfer amounts.
5. Regulator CANNOT decrypt Alice's balance → agent calls `disclose(alice, regulator)` →
   regulator decrypts Alice's balance → regulator still CANNOT decrypt Bob's balance.
5b. Non-agent calling `disclose` reverts.
5c. After `disclose`, Alice receives another transfer → regulator CANNOT decrypt the new
    balance handle (snapshot semantics).
- Extend the Rwa force-transfer test: after the forced transfer, the registrar can decrypt both
  new balances and the transferred amount (proves `_update` composition).

## Deploy script / demo.ts
- Deploy: set registrar. No jurisdictions, no regulator mapping. Keep a regulator address in
  the env for the demo.
- demo.ts: replace the "decrypt as each regulator" step with:
  regulator tries to decrypt Alice (fails) → issuer calls `disclose(alice, regulator)` →
  regulator decrypts Alice's balance (succeeds).
  