// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {externalEuint64, euint64} from "encrypted-types/EncryptedTypes.sol";
import {ConfidentialStock} from "../src/ConfidentialStock.sol";

contract ConfidentialStockTest is FhevmTest {
    ConfidentialStock stock;
    address stockAddress;

    address issuer = makeAddr("issuer");
    Account treasury;
    Account alice;
    Account bob;

    uint64 constant SUPPLY = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        treasury = makeAccount("treasury");
        stock = new ConfidentialStock("Confidential ACME", "cACME", "", issuer, treasury.addr);
        stockAddress = address(stock);
        alice = makeAccount("alice");
        bob = makeAccount("bob");
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
}
