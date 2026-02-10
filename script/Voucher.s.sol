// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {Voucher} from "../src/Voucher.sol";

contract DeployVoucher is Script {
    function run() external {
        address tokenAddress = vm.envAddress("MY_ERC20_ADDRESS");

        vm.startBroadcast();
        new Voucher(tokenAddress);
        vm.stopBroadcast();
    }
}