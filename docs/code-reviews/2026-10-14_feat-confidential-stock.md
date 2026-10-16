# Code Review: feat/confidential-stock
**Commit:** 8fc3237 (uncommitted additions)
**Date:** 2026-10-14
**Reviewer:** Codex
**Status:** pending

---

## Summary

The implemented mint/distribution subset passes all five tests (`forge test --offline`). Three required contract capabilities are still absent relative to SPEC.md; these are completion gaps in the current snapshot, not failures of the implemented mint path. Review scope: the two new Solidity files only.

---

## Warning

### WR-001: Implement register-access ACL grants
- **File:** src/ConfidentialStock.sol:15-16
- **Issue:** No registrar/regulator configuration or `_update` override exists.
- **Why it matters:** Inherited ERC7984 only grants balances and transfer handles to the contract and participating holders, so customer service and jurisdictional regulators cannot decrypt the register.
- **Suggested fix:** Add the registrar-admin role, configuration mappings/setters, and the specified post-update grants; test both authorized and unauthorized decryptions.
- **Resolution:** pending
- **Author notes:**

### WR-002: Implement issuer-controlled corporate actions
- **File:** src/ConfidentialStock.sol:23-24
- **Issue:** The multiplier is initialized but never updated, and `applyCorporateAction` is absent.
- **Why it matters:** Neither splits nor reinvested dividends can be demonstrated, and published supply cannot reflect them.
- **Suggested fix:** Add the issuer-only ratio update and event, document rounding, and test splits/dividends without changing raw balances.
- **Resolution:** pending
- **Author notes:**

### WR-003: Implement treasury-only burning
- **File:** src/ConfidentialStock.sol:45-48
- **Issue:** There is no external issuer-controlled burn operation.
- **Why it matters:** Shares returned to treasury cannot be retired or removed from published supply.
- **Suggested fix:** Add the specified treasury burn and supply accounting; handle ERC7984 silent failure so plaintext and encrypted supplies cannot diverge.
- **Resolution:** pending
- **Author notes:**
