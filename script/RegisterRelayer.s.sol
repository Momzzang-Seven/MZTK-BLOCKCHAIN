// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";

contract RegisterRelayer is Script {
    function run() external {
        // Load deployed contract addresses from environment
        address marketplaceEscrow = vm.envAddress("MARKETPLACE_ESCROW_ADDRESS");
        address qnaEscrow = vm.envAddress("QNA_ESCROW_ADDRESS");

        // Load relayer address to register (defaults to deployer if not set)
        address relayerAddress = vm.envOr("RELAYER_ADDRESS", vm.addr(vm.envUint("PRIVATE_KEY")));

        console.log("Relayer Address to register:", relayerAddress);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Register relayer in MarketplaceEscrow
        MarketplaceEscrow marketplace = MarketplaceEscrow(marketplaceEscrow);
        marketplace.updateRelayer(relayerAddress, true);
        console.log("[MarketplaceEscrow] Relayer updated for:", relayerAddress);
        console.log("  isRelayer:", marketplace.isRelayer(relayerAddress));

        // Register relayer in QnAEscrow
        QnAEscrow qna = QnAEscrow(qnaEscrow);
        qna.updateRelayer(relayerAddress, true);
        console.log("[QnAEscrow] Relayer updated for:", relayerAddress);
        console.log("  isRelayer:", qna.isRelayer(relayerAddress));

        vm.stopBroadcast();
    }
}
