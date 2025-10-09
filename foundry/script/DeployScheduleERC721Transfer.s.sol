// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScheduleERC721Transfer} from "src/ScheduleERC721Transfer.sol";
import {Script} from "forge-std/Script.sol";

contract DeployScheduleERC721Transfer is Script {
    function run() external returns (ScheduleERC721Transfer scheduleERC721Transfer) {
        vm.startBroadcast();
        scheduleERC721Transfer = new ScheduleERC721Transfer();
        vm.stopBroadcast();
    }
}
