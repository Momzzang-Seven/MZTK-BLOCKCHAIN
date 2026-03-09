// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";

contract DeployQnAEscrow is Script {
    function run() external {
        vm.startBroadcast();
        new QnAEscrow();
        vm.stopBroadcast();
    }
}
