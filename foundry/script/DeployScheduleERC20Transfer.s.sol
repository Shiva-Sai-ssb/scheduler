// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScheduleERC20Transfer} from "src/ScheduleERC20Transfer.sol";
import {Script} from "forge-std/Script.sol";

contract DeployScheduleERC20Transfer is Script {
    function run() external returns (ScheduleERC20Transfer scheduleERC20Transfer) {
        vm.startBroadcast();
        scheduleERC20Transfer = new ScheduleERC20Transfer();
        vm.stopBroadcast();
    }
}
