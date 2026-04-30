// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";

contract DeployMarketplaceEscrow is Script {
    function run() external {
        // Load the server signer address from environment
        address initialSigner = vm.envAddress("SIGNER_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        MarketplaceEscrow escrow = new MarketplaceEscrow(msg.sender, initialSigner);
        console.log("MarketplaceEscrow deployed at:", address(escrow));
        console.log("  owner  :", msg.sender);
        console.log("  signer :", initialSigner);
        vm.stopBroadcast();
    }
}
