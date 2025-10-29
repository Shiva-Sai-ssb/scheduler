// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScheduleETHTransfer} from "src/ScheduleETHTransfer.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployScheduleETHTransfer is Script {
    function run() external returns (ScheduleETHTransfer scheduleETHTransfer) {
        address chainlinkForwarder = vm.envAddress("CHAINLINK_FORWARDER_ADDRESS");

        vm.startBroadcast();
        scheduleETHTransfer = new ScheduleETHTransfer(chainlinkForwarder);
        vm.stopBroadcast();

        console.log("ScheduleETHTransfer deployed at:", address(scheduleETHTransfer));
        console.log("Forwarder set to:", chainlinkForwarder);
    }
}
