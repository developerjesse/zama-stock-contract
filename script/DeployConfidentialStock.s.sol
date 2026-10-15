// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ConfidentialStock} from "../src/ConfidentialStock.sol";

/// @notice Deploys ConfidentialStock and sets the registrar. Plaintext admin calls only: all encrypted interaction
///         (mint is plaintext, but distribution, decryption, disclosure) happens afterwards through the Zama SDK.
/// @dev Env:
///      DEPLOYER_PRIVATE_KEY  required. Becomes admin AND agent (issuer).
///      TREASURY_ADDRESS      optional, defaults to the deployer. Receives all minted shares.
///      REGISTRAR_ADDRESS     required. Customer-service address with standing access to every handle.
///      The regulator is NOT configured on-chain: it is granted per holder via `disclose` during the demo.
contract DeployConfidentialStock is Script {
    function run() external returns (ConfidentialStock stock) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address registrar = vm.envAddress("REGISTRAR_ADDRESS");

        vm.startBroadcast(deployerKey);

        stock = new ConfidentialStock("Confidential ACME", "cACME", "", deployer, treasury);
        stock.setRegistrar(registrar);

        vm.stopBroadcast();

        console.log("ConfidentialStock:", address(stock));
        console.log("  admin/agent:", deployer);
        console.log("  treasury:   ", treasury);
        console.log("  registrar:  ", registrar);
    }
}
