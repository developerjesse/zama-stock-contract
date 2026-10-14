// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {externalEuint64, euint64} from "encrypted-types/EncryptedTypes.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ConfidentialStock} from "../src/ConfidentialStock.sol";

contract ConfidentialStockTest is FhevmTest {
    ConfidentialStock stock;
    address stockAddress;

    address issuer = makeAddr("issuer");
    Account treasury;
    Account alice;
    Account bob;
    Account registrar;
    Account regulator;

    uint64 constant SUPPLY = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        treasury = makeAccount("treasury");
        stock = new ConfidentialStock("Confidential ACME", "cACME", "", issuer, treasury.addr);
        stockAddress = address(stock);
        alice = makeAccount("alice");
        bob = makeAccount("bob");
        registrar = makeAccount("registrar");
        regulator = makeAccount("regulator");
    }

    // --- helpers ---

    function _balanceOf(Account memory who, address holder) internal returns (uint256) {
        bytes memory sig = signUserDecrypt(who.key, stockAddress);
        return userDecrypt(euint64.unwrap(stock.confidentialBalanceOf(holder)), who.addr, stockAddress, sig);
    }

    function _transferFromTreasury(address to, uint64 amount) internal {
        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, treasury.addr, stockAddress);
        vm.prank(treasury.addr);
        stock.confidentialTransfer(to, enc, proof);
    }

    /// @dev External wrapper so `vm.expectRevert` can catch the internal decrypt helper's revert.
    function decryptExt(Account memory who, bytes32 handle) external returns (uint256) {
        return userDecrypt(handle, who.addr, stockAddress, signUserDecrypt(who.key, stockAddress));
    }

    function _assertCannotDecrypt(Account memory who, bytes32 handle) internal {
        // Flush recorded logs into the plaintext DB first: the reverted call below would otherwise swallow them.
        _processNewLogs();
        vm.expectRevert();
        this.decryptExt(who, handle);
    }

    function _handleOf(address holder) internal view returns (bytes32) {
        return euint64.unwrap(stock.confidentialBalanceOf(holder));
    }

    function _setRegistrar() internal {
        vm.prank(issuer);
        stock.setRegistrar(registrar.addr);
    }

    /// @dev Client-side display math: raw * multiplier / 1e18, rounded down.
    function _displayed(uint256 raw) internal view returns (uint256) {
        return (raw * stock.multiplier()) / 1e18;
    }

    function _mintToTreasury() internal {
        vm.prank(issuer);
        stock.mint(SUPPLY);
    }

    // --- 1. mint + supply ---

    function test_mintToTreasury_tracksSupply() public {
        _mintToTreasury();

        assertEq(stock.rawTotalSupply(), SUPPLY);
        assertEq(stock.publishedSupply(), SUPPLY);

        // Treasury holds the full minted amount.
        assertEq(_balanceOf(treasury, treasury.addr), SUPPLY);
    }

    // --- 2. confidential distribution ---

    function test_treasuryDistributesToAliceAndBob() public {
        _mintToTreasury();

        _transferFromTreasury(alice.addr, 600e6);
        _transferFromTreasury(bob.addr, 400e6);

        assertEq(_balanceOf(alice, alice.addr), 600e6);
        assertEq(_balanceOf(bob, bob.addr), 400e6);

        // Plaintext supply is unaffected by private distribution.
        assertEq(stock.rawTotalSupply(), SUPPLY);
    }

    // --- 8 (mint part). access control ---

    function test_nonIssuerCannotMint() public {
        // Read the role before pranking: the external call would otherwise consume the prank.
        bytes32 role = stock.AGENT_ROLE();
        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice.addr, role)
        );
        stock.mint(1);
    }

    function test_mintRevertsOnSupplyOverflow() public {
        vm.startPrank(issuer);
        stock.mint(type(uint64).max);
        vm.expectRevert();
        stock.mint(1);
        vm.stopPrank();
    }

    // --- 9. silent failure ---

    function test_transferExceedingBalanceMovesZero() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        // Alice tries to send more than she has: no revert, nothing moves.
        (externalEuint64 enc, bytes memory proof) = encryptUint64(150e6, alice.addr, stockAddress);
        vm.prank(alice.addr);
        stock.confidentialTransfer(bob.addr, enc, proof);

        assertEq(_balanceOf(alice, alice.addr), 100e6);
        assertEq(_balanceOf(bob, bob.addr), 0);
    }

    // --- Rwa: agent force transfer (lawful order / lost keys) ---

    function test_agentForceTransfer() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        (externalEuint64 enc, bytes memory proof) = encryptUint64(40e6, issuer, stockAddress);
        vm.prank(issuer);
        stock.forceConfidentialTransferFrom(alice.addr, bob.addr, enc, proof);

        assertEq(_balanceOf(alice, alice.addr), 60e6);
        assertEq(_balanceOf(bob, bob.addr), 40e6);
    }

    function test_nonAgentCannotForceTransfer() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        bytes32 role = stock.AGENT_ROLE();
        (externalEuint64 enc, bytes memory proof) = encryptUint64(40e6, bob.addr, stockAddress);
        vm.prank(bob.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob.addr, role)
        );
        stock.forceConfidentialTransferFrom(alice.addr, bob.addr, enc, proof);
    }

    // --- Rwa's own mint/burn are disabled ---

    function test_rwaConfidentialMintAndBurnDisabled() public {
        (externalEuint64 enc, bytes memory proof) = encryptUint64(1, issuer, stockAddress);
        vm.startPrank(issuer);
        vm.expectRevert(ConfidentialStock.MintBurnDisabled.selector);
        stock.confidentialMint(alice.addr, enc, proof);
        vm.expectRevert(ConfidentialStock.MintBurnDisabled.selector);
        stock.confidentialBurn(alice.addr, enc, proof);
        vm.stopPrank();
    }

    // --- 6. 2-for-1 split ---

    function test_split_doublesDisplayedBalancesAndSupply() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);
        _transferFromTreasury(bob.addr, 400e6);

        vm.expectEmit(address(stock));
        emit ConfidentialStock.CorporateAction("split", 2, 1, 2e18);
        vm.prank(issuer);
        stock.applyCorporateAction(2, 1, "split");

        assertEq(stock.multiplier(), 2e18);

        // Raw encrypted balances are untouched; only the client-side display changes.
        assertEq(_balanceOf(alice, alice.addr), 600e6);
        assertEq(_balanceOf(bob, bob.addr), 400e6);
        assertEq(_displayed(_balanceOf(alice, alice.addr)), 1200e6);
        assertEq(_displayed(_balanceOf(bob, bob.addr)), 800e6);

        assertEq(stock.rawTotalSupply(), SUPPLY);
        assertEq(stock.publishedSupply(), 2 * uint256(SUPPLY));
    }

    // --- 7. reinvested dividend + rounding ---

    function test_reinvestedDividend_scalesAndRoundsDown() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);
        _transferFromTreasury(bob.addr, 199); // 199 raw units: 199 * 1.005 = 199.995 -> 199

        vm.prank(issuer);
        stock.applyCorporateAction(1005, 1000, "dividend");

        assertEq(stock.multiplier(), 1.005e18);
        assertEq(_displayed(_balanceOf(alice, alice.addr)), 603e6);
        assertEq(_displayed(_balanceOf(bob, bob.addr)), 199);
        assertEq(stock.publishedSupply(), 1_005_000e6);
    }

    function test_actionsCompound() public {
        vm.startPrank(issuer);
        stock.applyCorporateAction(2, 1, "split");
        stock.applyCorporateAction(1005, 1000, "dividend");
        vm.stopPrank();
        assertEq(stock.multiplier(), 2.01e18);
    }

    function test_multiplierRoundsDown() public {
        vm.prank(issuer);
        stock.applyCorporateAction(1, 3, "odd-ratio");
        assertEq(stock.multiplier(), 333333333333333333);
    }

    // --- 8 (corporate action part) + input validation ---

    function test_nonAgentCannotApplyCorporateAction() public {
        bytes32 role = stock.AGENT_ROLE();
        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice.addr, role)
        );
        stock.applyCorporateAction(2, 1, "split");
    }

    function test_corporateActionRejectsBadInputs() public {
        vm.startPrank(issuer);
        vm.expectRevert(ConfidentialStock.InvalidCorporateAction.selector);
        stock.applyCorporateAction(0, 1, "x");
        vm.expectRevert(ConfidentialStock.InvalidCorporateAction.selector);
        stock.applyCorporateAction(1, 0, "x");
        // rounds to a zero multiplier
        vm.expectRevert(ConfidentialStock.InvalidCorporateAction.selector);
        stock.applyCorporateAction(1, 2e18 + 1, "x");
        // exceeds the uint192 upper bound
        vm.expectRevert(ConfidentialStock.InvalidCorporateAction.selector);
        stock.applyCorporateAction(type(uint192).max, 1, "x");
        vm.stopPrank();
    }

    // --- fractional shares (6 decimals) ---

    function test_fractionalShares_scaleExactlyWhenDivisible() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 1_500_000); // 1.5 shares

        vm.prank(issuer);
        stock.applyCorporateAction(1005, 1000, "dividend");

        assertEq(_displayed(_balanceOf(alice, alice.addr)), 1_507_500); // 1.5075 shares
    }

    function test_resolutionCoarsensAfterSplit() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 1_000_000); // 1.0 share

        vm.prank(issuer);
        stock.applyCorporateAction(3, 1, "split");

        // One raw unit now displays as 3 micro-shares.
        assertEq(_displayed(1), 3);
        assertEq(_displayed(_balanceOf(alice, alice.addr)), 3_000_000);

        // Converting "1.0 share" (1e6 display units) back to raw rounds down, so it comes out slightly under 1.0.
        uint256 raw = (1_000_000 * 1e18) / stock.multiplier(); // 333_333
        assertEq(raw, 333_333);
        assertEq(_displayed(raw), 999_999);
    }

    // --- 3. holder isolation ---

    function test_holdersCannotDecryptEachOther() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);
        _transferFromTreasury(bob.addr, 400e6);

        assertEq(_balanceOf(alice, alice.addr), 600e6);
        assertEq(_balanceOf(bob, bob.addr), 400e6);
        _assertCannotDecrypt(alice, _handleOf(bob.addr));
        _assertCannotDecrypt(bob, _handleOf(alice.addr));
    }

    // --- 4. registrar standing access ---

    function test_registrarDecryptsBalancesAndTransferAmounts() public {
        _setRegistrar();
        _mintToTreasury();

        (externalEuint64 enc, bytes memory proof) = encryptUint64(600e6, treasury.addr, stockAddress);
        vm.prank(treasury.addr);
        euint64 sent = stock.confidentialTransfer(alice.addr, enc, proof);
        _transferFromTreasury(bob.addr, 400e6);

        assertEq(_balanceOf(registrar, alice.addr), 600e6);
        assertEq(_balanceOf(registrar, bob.addr), 400e6);
        assertEq(_balanceOf(registrar, treasury.addr), SUPPLY - 1000e6);
        assertEq(_decryptHandle(registrar, euint64.unwrap(sent)), 600e6);
    }

    function _decryptHandle(Account memory who, bytes32 handle) internal returns (uint256) {
        return userDecrypt(handle, who.addr, stockAddress, signUserDecrypt(who.key, stockAddress));
    }

    function test_onlyAdminSetsRegistrar() public {
        bytes32 role = stock.DEFAULT_ADMIN_ROLE();
        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice.addr, role)
        );
        stock.setRegistrar(alice.addr);
    }

    // --- 5. regulator on-request disclosure ---

    function test_discloseGivesRegulatorAccessToOneHolderOnly() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);
        _transferFromTreasury(bob.addr, 400e6);

        _assertCannotDecrypt(regulator, _handleOf(alice.addr));

        vm.expectEmit(address(stock));
        emit ConfidentialStock.Disclosed(alice.addr, regulator.addr, _handleOf(alice.addr));
        vm.prank(issuer);
        stock.disclose(alice.addr, regulator.addr);

        assertEq(_balanceOf(regulator, alice.addr), 600e6);
        _assertCannotDecrypt(regulator, _handleOf(bob.addr));
    }

    function test_nonAgentCannotDisclose() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);

        bytes32 role = stock.AGENT_ROLE();
        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice.addr, role)
        );
        stock.disclose(alice.addr, regulator.addr);
    }

    function test_discloseRevertsForHolderWithNoBalance() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ConfidentialStock.NothingToDisclose.selector, bob.addr));
        stock.disclose(bob.addr, regulator.addr);
    }

    function test_disclosureIsASnapshot() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 600e6);

        vm.prank(issuer);
        stock.disclose(alice.addr, regulator.addr);
        assertEq(_balanceOf(regulator, alice.addr), 600e6);

        // Alice receives more: new balance handle, regulator has no access to it.
        _transferFromTreasury(alice.addr, 100e6);
        assertEq(_balanceOf(alice, alice.addr), 700e6);
        _assertCannotDecrypt(regulator, _handleOf(alice.addr));
    }

    // --- Rwa force transfer composes with registrar access ---

    function test_forceTransferStillGrantsRegistrar() public {
        _setRegistrar();
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        (externalEuint64 enc, bytes memory proof) = encryptUint64(40e6, issuer, stockAddress);
        vm.prank(issuer);
        euint64 moved = stock.forceConfidentialTransferFrom(alice.addr, bob.addr, enc, proof);

        assertEq(_balanceOf(registrar, alice.addr), 60e6);
        assertEq(_balanceOf(registrar, bob.addr), 40e6);
        assertEq(_decryptHandle(registrar, euint64.unwrap(moved)), 40e6);
    }

    // --- force transfer must not be usable as a mint/burn backdoor ---

    function test_forceTransferRejectsZeroEndpoints_proofOverload() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        (externalEuint64 enc, bytes memory proof) = encryptUint64(40e6, issuer, stockAddress);
        vm.startPrank(issuer);
        // zero `from` would mint to an arbitrary recipient without touching rawTotalSupply
        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984InvalidSender.selector, address(0)));
        stock.forceConfidentialTransferFrom(address(0), bob.addr, enc, proof);
        // zero `to` would burn
        (enc, proof) = encryptUint64(40e6, issuer, stockAddress);
        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984InvalidReceiver.selector, address(0)));
        stock.forceConfidentialTransferFrom(alice.addr, address(0), enc, proof);
        vm.stopPrank();
    }

    function test_forceTransferRejectsZeroEndpoints_handleOverload() public {
        _mintToTreasury();
        _transferFromTreasury(alice.addr, 100e6);

        // A forced transfer leaves the agent with ACL on `moved`, which the handle overload requires.
        (externalEuint64 enc, bytes memory proof) = encryptUint64(10e6, issuer, stockAddress);
        vm.startPrank(issuer);
        euint64 moved = stock.forceConfidentialTransferFrom(alice.addr, bob.addr, enc, proof);

        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984InvalidSender.selector, address(0)));
        stock.forceConfidentialTransferFrom(address(0), bob.addr, moved);
        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984InvalidReceiver.selector, address(0)));
        stock.forceConfidentialTransferFrom(alice.addr, address(0), moved);
        vm.stopPrank();
    }
}
