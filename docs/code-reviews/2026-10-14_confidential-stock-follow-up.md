# ConfidentialStock follow-up findings

Date: 2026-10-14
Status: open

The preceding review reported two independently reproduced defects despite all 24 existing tests passing. This file records those findings and the subsequent clarification of P2. No fixes or additional reproduction tests were performed when writing this file.

## P1: Reject zero-address endpoints in forced transfers

- Location: `src/ConfidentialStock.sol`, `_forceUpdate` (lines 124–125).
- Status: open; prioritize for the POC.

Either inherited force-transfer overload allows an agent to pass a zero `from` or `to`. The force path bypasses `_transfer`'s address checks, and the base update interprets these endpoints as minting or burning. A zero `from` therefore allows issuance directly to an arbitrary recipient; a zero `to` allows burning. Neither operation updates `rawTotalSupply`.

This bypasses treasury-only issuance and makes `publishedSupply()` inconsistent with the encrypted supply. The preceding review reported temporary reproduction tests confirming both paths.

Suggested fix: reject both zero endpoints in `_forceUpdate` before calling the base implementation, using the corresponding invalid-sender and invalid-receiver errors. Verify that both inherited overloads reject mint/burn endpoints and ordinary forced transfers still work.

## P2: Grant registrar access to the final transfer-and-call result

- Location: `src/ConfidentialStock.sol`, `_update` (lines 109–111), and the inherited ERC7984 `_transferAndCall` implementation.
- Status: open; reasonable to defer for a POC that only demonstrates ordinary confidential transfers.

The registrar is granted access to the intermediate sent and refund handles through `_update`. The inherited `_transferAndCall` subsequently computes `FHE.sub(sent, refund)` and returns a distinct encrypted handle. Permissions on the inputs do not automatically grant the registrar access to this new result.

For example, an accepted transfer of 10 shares produces an encrypted sent amount of 10 and a refund amount of 0. The registrar can decrypt those handles and the updated balances, but cannot directly decrypt the new handle representing the final net amount of 10. The preceding review reported a temporary test confirming that the registrar could decrypt the updated balance but not the returned amount.

This is an access-completeness defect against the documented standing-access guarantee for every transfer handle. It does not corrupt balances, change supply, or expose confidential data. The registrar could derive the net amount if it has both intermediate handles. Ordinary confidential transfers do not encounter this particular gap.

Suggested fix, corrected after inspecting the installed dependency: `_transferAndCall` is not `virtual` in OpenZeppelin confidential-contracts 0.4.0, so the original recommendation to override it directly is not implementable. Use an available override point, such as the public transfer-and-call entry points, to grant the token and registrar access to the final returned handle. Cover all inherited transfer-and-call overloads and verify access for both accepted and refunded transfers.

POC recommendation: fix P1 first. Defer P2 with this documented limitation unless transfer-and-call is part of the demo or acceptance criteria.
