// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScheduleETHTransfer} from "src/ScheduleETHTransfer.sol";
import {Script} from "forge-std/Script.sol";

contract DeployScheduleETHTransfer is Script {
    function run() external returns (ScheduleETHTransfer scheduleETHTransfer) {
        vm.startBroadcast();
        scheduleETHTransfer = new ScheduleETHTransfer();
        vm.stopBroadcast();
    }
}
