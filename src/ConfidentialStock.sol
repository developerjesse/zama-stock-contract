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
contract ConfidentialStock is ZamaEthereumConfig, ERC7984Rwa {
    error MintBurnDisabled();

    uint256 internal constant MULTIPLIER_ONE = 1e18;

    /// @notice Issuer treasury. The only address that receives minted shares.
    address public immutable treasury;

    /// @notice Fixed-point rebase multiplier, `1e18 = 1.0`.
    uint256 public multiplier = MULTIPLIER_ONE;

    /// @notice Plaintext raw share supply (before multiplier). Primary issuance matches custodian shares, which are
    ///         public anyway.
    uint64 public rawTotalSupply;

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

    /// @notice Total supply as published to CMC/CG: `rawTotalSupply * multiplier / 1e18` (rounds down).
    function publishedSupply() external view returns (uint256) {
        return (uint256(rawTotalSupply) * multiplier) / MULTIPLIER_ONE;
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
