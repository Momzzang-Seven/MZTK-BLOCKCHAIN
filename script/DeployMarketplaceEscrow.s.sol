// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";

contract DeployMarketplaceEscrow is Script {
    function run() external {
        address tokenAddress = vm.envAddress("MY_ERC20_ADDRESS");

        vm.startBroadcast();
        new MarketplaceEscrow(tokenAddress);
        vm.stopBroadcast();
    }
}
