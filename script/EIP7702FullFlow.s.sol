// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {NonceTracker} from "../src/NonceTracker.sol";
import {DefaultReceiver} from "../src/DefaultReceiver.sol";
import {EIP7702Proxy} from "../src/EIP7702Proxy.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";

contract DeployFullSystem is Script {
    function run() external {
        vm.startBroadcast();

        NonceTracker tracker = new NonceTracker();
        console2.log("NonceTracker deployed at:", address(tracker));

        DefaultReceiver receiver = new DefaultReceiver();
        console2.log("DefaultReceiver deployed at:", address(receiver));

        EIP7702Proxy proxy = new EIP7702Proxy(address(tracker), address(receiver));
        console2.log("EIP7702Proxy deployed at:", address(proxy));

        BatchImplementation impl = new BatchImplementation();
        console2.log("BatchImplementation deployed at:", address(impl));

        vm.stopBroadcast();

        console2.log("\n--- Copy these to your .env file ---");
        console2.log("NONCE_TRACKER_ADDR=", address(tracker));
        console2.log("DEFAULT_RECEIVER_ADDR=", address(receiver));
        console2.log("PROXY_ADDR=", address(proxy));
        console2.log("BATCH_IMPL_ADDR=", address(impl));
    }
}