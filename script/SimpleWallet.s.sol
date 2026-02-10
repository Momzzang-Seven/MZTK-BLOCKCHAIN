// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {SimpleWallet} from "../src/SimpleWallet.sol";

contract DeploySimpleWallet is Script {
    function run() external {
        vm.startBroadcast();

        new SimpleWallet();

        vm.stopBroadcast();
    }
}