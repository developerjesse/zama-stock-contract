// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ERC7984Rwa} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984Rwa.sol";

/// @title ConfidentialStock
/// @notice A confidential tokenized stock where balances are encrypted (ERC7984). The issuance is in plaintext
///         and are minted to the treasury address. Individual allocations always stay private.
/// @dev Encrypted balances hold RAW shares to 6 decimals. Any display change takes the raw amount and 
///      multiplies it against the `multiplier` which represents splits, or dividends
/// @dev Fractional shares: the underlining issuer, needs to accept and handle fractional shares for the
///      for the balances to work. Display amounts always round down, which is a percision issue.
contract ConfidentialStock is ZamaEthereumConfig, ERC7984Rwa {
    error MintBurnDisabled();
    error InvalidCorporateAction();
    error MultiplierMismatch(uint256 expected, uint256 actual);
    error NothingToDisclose(address holder);
    error NotRepresentable(uint256 shares, uint256 multiplier);

    event RegistrarSet(address indexed registrar);
    /// @dev The fact that you call the `Disclosed(address)` already leaks that this has happened 
    event Disclosed(address indexed holder, address indexed regulator, bytes32 balanceHandle);
    event CorporateAction(string kind, uint256 oldMultiplier, uint256 newMultiplier);

    /// @dev Starting multiplier is 1
    uint256 internal constant MULTIPLIER_ONE = 1e18;

    /// @notice Issuer treasury who receives minted shares.
    address public immutable treasury;

    /// @notice Fixed-point rebase multiplier, `1e18 = 1.0`.
    uint256 public multiplier = MULTIPLIER_ONE;

    /// @notice Plaintext raw share supply (before multiplier) which is used to inform CMC/CG
    uint64 public rawTotalSupply;

    /// @dev the issuers internal auditor or customer-service address with ACL access to all balances and transfers
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

    /// @notice Mints shares to the treasury. Converts to raw units via the current `multiplier`, so it works
    ///         for initial issuance (multiplier 1e18) and after a corporate action.
    function mintShares(uint256 shares) external onlyAgent {
        (uint256 raw, bool exact) = sharesToRaw(shares);
        require(exact, NotRepresentable(shares, multiplier));
        require(raw <= type(uint64).max, NotRepresentable(shares, multiplier));
        _mintRaw(uint64(raw));
    }

    /// @notice Takes the raw shares multipled by the `multiplier` returning a display value. It rounds down
    ///         which may lead to inpercision at the dust level.
    function sharesToRaw(uint256 shares) public view returns (uint256 raw, bool exact) {
        uint256 m = multiplier;
        raw = Math.mulDiv(shares, MULTIPLIER_ONE, m);
        exact = Math.mulDiv(raw, m, MULTIPLIER_ONE) == shares;
    }

    function _mintRaw(uint64 rawAmount) internal {
        rawTotalSupply += rawAmount;
        _mint(treasury, FHE.asEuint64(rawAmount));
    }

    /// @notice Sets the registrar that gets standing access to all future balance and transfer handles.
    function setRegistrar(address newRegistrar) external onlyAdmin {
        registrar = newRegistrar;
        emit RegistrarSet(newRegistrar);
    }

    /// @notice Disclose a current balance handle to a regulator.
    function disclose(address holder, address regulator) external onlyAgent {
        euint64 bal = confidentialBalanceOf(holder);
        require(FHE.isInitialized(bal), NothingToDisclose(holder));
        FHE.allow(bal, regulator);
        emit Disclosed(holder, regulator, euint64.unwrap(bal));
    }

    /// @notice Sets the absolute multiplier for a rebase-type action such as a split, or a reinvestment of a dividend.
    /// @dev The new value is computed off-chain, so rounding never compounds on-chain. `expectedOld` must match the
    ///      current multiplier, which makes a correction a reissue from the same old value: if a wrong value was
    ///      set, call again with the wrong value as `expectedOld`. There are no FHE operations here because the
    ///      encrypted raw balance does not need to change, only the public `multiplier`.
    function setMultiplier(uint256 expectedOld, uint256 newMultiplier, string calldata kind) external onlyAgent {
        uint256 oldMultiplier = multiplier;
        require(oldMultiplier == expectedOld, MultiplierMismatch(expectedOld, oldMultiplier));
        require(newMultiplier != 0 && newMultiplier <= type(uint192).max, InvalidCorporateAction());
        multiplier = newMultiplier;
        emit CorporateAction(kind, oldMultiplier, newMultiplier);
    }

    /// @notice Total supply as published to CMC/CG: `rawTotalSupply * multiplier / 1e18` (rounds down).
    function publishedSupply() external view returns (uint256) {
        return (uint256(rawTotalSupply) * multiplier) / MULTIPLIER_ONE;
    }

    /// @dev triggers after a mintShares() or transfer() and passes the amount and addresses involved. 
    function _update(address from, address to, euint64 amount) internal override returns (euint64 transferred) {
        transferred = super._update(from, to, amount);
        _grantRegistrar(from, to, transferred);
    }

    /// @dev Grants access to the Registrar role to the balance handle at this point in time.
    /// @dev is ignored if the registrar role is not set, or if burning (send to 0x0) and minting.
    function _grantRegistrar(address from, address to, euint64 transferred) internal {
        address reg = registrar;
        if (reg == address(0)) return;
        FHE.allow(transferred, reg);
        if (from != address(0)) FHE.allow(confidentialBalanceOf(from), reg);
        if (to != address(0)) FHE.allow(confidentialBalanceOf(to), reg);
    }

    /// @dev This is out-of-the-box with ERC7984RWA, and can be triggered by lost keys or court orders. We need 
    ///.     to override it here so we can call _grantRegistrar.
    function _forceUpdate(address from, address to, euint64 amount) internal override returns (euint64 transferred) {
        // The force path skips `_transfer`'s address checks, and a zero endpoint is interpreted by `_update` as a
        // mint (from) or burn (to). Reject both so force transfer cannot bypass treasury-only issuance or desync
        // `rawTotalSupply`.
        require(from != address(0), ERC7984InvalidSender(address(0)));
        require(to != address(0), ERC7984InvalidReceiver(address(0)));
        transferred = super._forceUpdate(from, to, amount);
        _grantRegistrar(from, to, transferred);
    }

    // --- Rwa mint/burn are disabled ---
    function confidentialMint(address, externalEuint64, bytes calldata) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    function confidentialMint(address, euint64) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    // Out of scope for the MVP:s
    function confidentialBurn(address, externalEuint64, bytes calldata) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }

    function confidentialBurn(address, euint64) public pure override returns (euint64) {
        revert MintBurnDisabled();
    }
}
