# Confidential Stock — Build Spec (Zama trial, build slice)

## Goal
A native confidential tokenized stock that an issuer can actually operate:
corporate actions (splits, reinvested dividends) and register access for
customer service and per-jurisdiction regulators. Deployed and demoable on Sepolia.

Out of scope: ERC-20 wrapping/unwrapping, cash (USDC) dividends, identity/KYC
registry, exchange integration, Safe/Fireblocks (possible stretch later).

## Setup
- Start from https://github.com/zama-ai/fhevm-foundry-template (deps via
  `forge soldeer install`; tests use forge-fhevm's in-memory mock).
- Add OpenZeppelin confidential contracts (latest) — via soldeer if published
  there, otherwise as a git dependency with a remapping. Make sure its
  `@fhevm/solidity` version matches the template's.
- **Read the installed source of `ERC7984.sol` before writing code** — confirm the
  internal transfer hook name/signature (expected `_update(from, to, amount)`
  returning the transferred handle) and how it grants ACL to holders. Do not modify OZ code.
- IMPORTANT: forge tests and decrypting forge scripts only work against the
  local mock, never Sepolia. Deploy to Sepolia with `forge script --broadcast`,
  but all Sepolia interaction (encrypt inputs, transfers, decryption) must go
  through the Zama SDK from TypeScript.

## Contract: `ConfidentialStock is ERC7984` (+ AccessControl or Ownable2Step)

### Roles
- `ISSUER_ROLE`: mint, burn, corporate actions.
- `REGISTRAR_ADMIN_ROLE`: set registrar, set regulators, assign holder jurisdictions.

### Balances and supply
- Encrypted balances hold **raw shares** (`euint64`, 6 decimals).
- `uint256 public multiplier` — fixed point, `1e18 = 1.0`.
- Displayed balance = decrypt(raw) * multiplier / 1e18 — computed **client-side only**.
  The contract never multiplies encrypted values.
- `uint64 public rawTotalSupply` — plaintext, tracked on mint/burn.
  `publishedSupply() = rawTotalSupply * multiplier / 1e18` (supports the daily
  CMC/CG supply publication requirement).

### Issuance (privacy-preserving)
- `mintShares(uint256 shares)` — plaintext amount, mints to the issuer **treasury**
  address only. Primary issuance matches custodian shares, which are public anyway.
- Distribution to holders is a normal confidential transfer from treasury, so
  individual allocations stay private.
- `burn(uint64 rawAmount)` — from treasury only.

### Corporate actions (zero FHE ops)
- `setMultiplier(uint256 expectedOld, uint256 newMultiplier, string kind)`
  - Absolute value computed off-chain (xStocks model). Reverts `MultiplierMismatch(expected, actual)` if `multiplier != expectedOld`.
  - 2-for-1 split: 2e18. Reinvested dividend of $0.50 on $100: 1.005e18.
  - A mistake is corrected by calling again with the wrong value as `expectedOld`.
  - Emits `CorporateAction(kind, oldMultiplier, newMultiplier)`.
- Note in comments: one multiplier = one uniform withholding rate for all holders.

### Register access (the FHE/ACL part)
- `address public registrar` — issuer CS; gets ACL on every balance and transfer handle.
- `mapping(bytes32 => address) public regulatorFor` — jurisdiction code → regulator address.
- `mapping(address => bytes32) public jurisdictionOf` — holder → jurisdiction.
- Override `_update`: after `super._update(...)`, for each non-zero of `from`/`to`:
  - `FHE.allow(newBalanceHandle, registrar)`
  - `FHE.allow(newBalanceHandle, regulatorFor[jurisdictionOf[account]])` if set
  - Same for the transferred-amount handle (registrar + both parties' regulators).
- Changing a holder's jurisdiction or regulator only affects **future** handles
  (ACL grants can't be revoked). Document this as a known limitation.

## Tests (mock mode)
1. Issuer mints to treasury; `rawTotalSupply` and `publishedSupply()` correct.
2. Treasury transfers confidentially to Alice (jurisdiction DE) and Bob (jurisdiction FR).
3. Alice and Bob each decrypt their own balance; cannot decrypt each other's.
4. Registrar decrypts both balances and the transfer amounts.
5. DE regulator decrypts Alice's balance but **not** Bob's; FR regulator the reverse.
6. 2-for-1 split: raw balances unchanged, multiplier 2e18, displayed balance doubles,
   `publishedSupply()` doubles.
7. Reinvested dividend (1005/1000): displayed balances scale correctly; rounding checked.
8. Non-issuer cannot mint, burn, or apply corporate actions.
9. Transfer exceeding balance moves 0 (ERC7984 silent-failure behaviour) — no revert.

## Scripts
- `script/DeployConfidentialStock.s.sol` — forge deploy to Sepolia; set registrar,
  two regulators, two jurisdictions (plaintext admin calls only).
- `demo/demo.ts` — Node/TypeScript using the Zama SDK, end-to-end on Sepolia:
  mint, distribute (encrypted input), decrypt as holder, split, dividend, decrypt
  as registrar and as each regulator. Print clear before/after output.
  This is the fallback demo if the dapp isn't finished, and its SDK code is
  reused by the dapp tomorrow.

## Watch-outs
- Every new handle needs `FHE.allowThis` + holder allow (OZ handles holders;
  verify) — missing ACL is the most likely bug.
- Multiplier rounding: decide and document the rounding direction.
- `euint64` with 6 decimals caps raw supply at ~18.4T shares (fine for equities).
- Keep the contract small. No hooks/compliance modules unless everything above passes.
