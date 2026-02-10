// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {MyERC20} from "../src/MyERC20.sol";

contract DeployMyERC20 is Script {
    function run() external {
        vm.startBroadcast();

        new MyERC20("MZTK Token", "MZTK", 1000 * 10**18);

        vm.stopBroadcast();
    }
}