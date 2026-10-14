// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ERC7984Rwa} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984Rwa.sol";

/// @title ConfidentialStock
/// @notice A confidential tokenized stock. Balances and transfers are encrypted (ERC7984); issuance is plaintext
///         and always lands in the issuer treasury, so individual allocations stay private.
/// @dev Built on ERC7984Rwa, which brings AccessControl, pause, freeze, block/allow lists and agent force-transfer.
///      The issuer is the Rwa AGENT (`AGENT_ROLE`); the admin (`DEFAULT_ADMIN_ROLE`) manages agents.
/// @dev Encrypted balances hold RAW shares (6 decimals). The displayed balance is
///      `decrypt(raw) * multiplier / 1e18`, computed client-side only. The contract never multiplies encrypted values.
/// @dev Fractional shares: 1 share = 1e6 raw units. Raw precision is fixed, so the smallest unit a holder can transact
///      is `multiplier * 1e-6` shares (exactly 1e-6 only while multiplier == 1.0; coarser after splits, finer after
///      reverse splits). Display amounts round down.
contract ConfidentialStock is ZamaEthereumConfig, ERC7984Rwa {
    error MintBurnDisabled();
    error InvalidCorporateAction();
    error NothingToDisclose(address holder);

    event RegistrarSet(address indexed registrar);
    /// @dev Public audit trail of regulator disclosures. It also signals that a regulator is looking at `holder`.
    ///      TODO(open design question): keep the event, or move the audit trail off-chain.
    event Disclosed(address indexed holder, address indexed regulator, bytes32 balanceHandle);
    event CorporateAction(string kind, uint256 numerator, uint256 denominator, uint256 newMultiplier);

    uint256 internal constant MULTIPLIER_ONE = 1e18;

    /// @notice Issuer treasury. The only address that receives minted shares.
    address public immutable treasury;

    /// @notice Fixed-point rebase multiplier, `1e18 = 1.0`.
    uint256 public multiplier = MULTIPLIER_ONE;

    /// @notice Plaintext raw share supply (before multiplier). Primary issuance matches custodian shares, which are
    ///         public anyway.
    uint64 public rawTotalSupply;

    /// @notice Issuer customer-service address with standing ACL access to every balance and transfer handle.
    /// @dev Changing the registrar only affects FUTURE handles: the previous registrar keeps access to handles it was
    ///      already granted (ACL grants are not revocable).
    address public registrar;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        address admin,
        address treasury_
    ) ERC7984(name_, symbol_, contractURI_) ERC7984Rwa(admin) {
        require(treasury_ != address(0), "treasury is zero");
        treasury = treasury_;
        _grantRole(AGENT_ROLE, admin);
    }

    /// @notice Mints `rawAmount` raw shares to the treasury. Reverts if `rawTotalSupply` would overflow `uint64`.
    /// @dev Distribution to holders is an ordinary confidential transfer from the treasury.
    function mint(uint64 rawAmount) external onlyAgent {
        rawTotalSupply += rawAmount;
        _mint(treasury, FHE.asEuint64(rawAmount));
    }

    /// @notice Sets the registrar that gets standing access to all future balance and transfer handles.
    function setRegistrar(address newRegistrar) external onlyAdmin {
        registrar = newRegistrar;
        emit RegistrarSet(newRegistrar);
    }

    /// @notice On-request regulator disclosure: lets `regulator` decrypt `holder`'s CURRENT balance.
    /// @dev Snapshot semantics: the grant is on the current balance handle only. Every balance change creates a new
    ///      handle, so future balances need another `disclose` call. Historical transfer amounts are shared off-chain
    ///      by the registrar (who holds ACL on all of them), which is out of scope for the contract.
    ///      The token holds `allowThis` on every balance handle (ERC7984 `_update`), so it can `allow` it onward.
    ///      TODO(may revisit): `disclose` lets any agent expose any holder's balance to any address. A compromised
    ///      agent key could disclose every balance. Consider a separate role or a holder-consent flow.
    function disclose(address holder, address regulator) external onlyAgent {
        euint64 bal = confidentialBalanceOf(holder);
        require(FHE.isInitialized(bal), NothingToDisclose(holder));
        FHE.allow(bal, regulator);
        emit Disclosed(holder, regulator, euint64.unwrap(bal));
    }

    /// @notice Applies a rebase-style corporate action: `multiplier = multiplier * numerator / denominator`.
    ///         2-for-1 split: (2, 1). Reinvested $0.50 dividend on a $100 share: (1005, 1000).
    /// @dev Zero FHE operations: encrypted raw balances never change, only the public multiplier does.
    ///      Rounding: the new multiplier rounds DOWN (1e18 precision, so at most 1e-18 relative error). Displayed
    ///      balances also round down client-side. A multiplier of 0 is rejected, and the upper bound keeps
    ///      `rawTotalSupply * multiplier` inside uint256 so `publishedSupply()` can never overflow.
    ///      NOTE: one multiplier means one uniform rate for all holders, so e.g. dividend withholding cannot differ
    ///      per holder.
    function applyCorporateAction(uint256 numerator, uint256 denominator, string calldata kind) external onlyAgent {
        require(numerator != 0 && denominator != 0, InvalidCorporateAction());
        uint256 newMultiplier = (multiplier * numerator) / denominator;
        require(newMultiplier != 0 && newMultiplier <= type(uint192).max, InvalidCorporateAction());
        multiplier = newMultiplier;
        emit CorporateAction(kind, numerator, denominator, newMultiplier);
    }

    /// @notice Total supply as published to CMC/CG: `rawTotalSupply * multiplier / 1e18` (rounds down).
    function publishedSupply() external view returns (uint256) {
        return (uint256(rawTotalSupply) * multiplier) / MULTIPLIER_ONE;
    }

    /// @dev Composes with ERC7984Rwa via `super`. Grants use the handle `super` RETURNS (Rwa may reduce the amount,
    ///      e.g. frozen balances) and the balances AFTER the update.
    function _update(address from, address to, euint64 amount) internal override returns (euint64 transferred) {
        transferred = super._update(from, to, amount);
        _grantRegistrar(from, to, transferred);
    }

    function _grantRegistrar(address from, address to, euint64 transferred) internal {
        address reg = registrar;
        if (reg == address(0)) return;
        FHE.allow(transferred, reg);
        if (from != address(0)) FHE.allow(confidentialBalanceOf(from), reg);
        if (to != address(0)) FHE.allow(confidentialBalanceOf(to), reg);
    }

    /// @dev ERC7984Rwa's force path calls `super._update` from inside Rwa, which resolves PAST our `_update` override,
    ///      so it needs its own hook or force transfers (lost keys, lawful orders) would skip the registrar grants.
    function _forceUpdate(address from, address to, euint64 amount) internal override returns (euint64 transferred) {
        transferred = super._forceUpdate(from, to, amount);
        _grantRegistrar(from, to, transferred);
    }

    // --- Rwa mint/burn are disabled ---
    // ERC7984Rwa exposes agent `confidentialMint`/`confidentialBurn` for arbitrary addresses and encrypted amounts.
    // Those would bypass the treasury-only rule and desync the plaintext `rawTotalSupply`, so issuance is only via
    // `mint` above and there is no burn.

    function confidentialMint(address, externalEuint64, bytes calldata) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    function confidentialMint(address, euint64) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    function confidentialBurn(address, externalEuint64, bytes calldata) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    function confidentialBurn(address, euint64) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }
}
