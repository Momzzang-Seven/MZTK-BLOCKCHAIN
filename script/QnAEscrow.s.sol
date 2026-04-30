// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";

contract DeployQnAEscrow is Script {
    function run() external {
        // Load the server signer address from environment
        address initialSigner = vm.envAddress("SIGNER_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        QnAEscrow escrow = new QnAEscrow(msg.sender, initialSigner);
        console.log("QnAEscrow deployed at:", address(escrow));
        console.log("  owner  :", msg.sender);
        console.log("  signer :", initialSigner);
        vm.stopBroadcast();
    }
}
