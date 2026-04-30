// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";

contract RegisterMZTToken is Script {
    function run() external {
        // Load deployed contract addresses from environment
        address marketplaceEscrow = vm.envAddress("MARKETPLACE_ESCROW_ADDRESS");
        address qnaEscrow         = vm.envAddress("QNA_ESCROW_ADDRESS");

        // Load MZT ERC20 token address from environment
        address mztToken = vm.envAddress("MZT_TOKEN_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Register MZT token in MarketplaceEscrow
        MarketplaceEscrow marketplace = MarketplaceEscrow(marketplaceEscrow);
        marketplace.updateTokenSupport(mztToken, true);
        console.log("[MarketplaceEscrow] MZT token registered:", mztToken);
        console.log("  isSupportedToken:", marketplace.isSupportedToken(mztToken));

        // Register MZT token in QnAEscrow
        QnAEscrow qna = QnAEscrow(qnaEscrow);
        qna.updateTokenSupport(mztToken, true);
        console.log("[QnAEscrow] MZT token registered:", mztToken);
        console.log("  isSupportedToken:", qna.isSupportedToken(mztToken));

        vm.stopBroadcast();
    }
}
