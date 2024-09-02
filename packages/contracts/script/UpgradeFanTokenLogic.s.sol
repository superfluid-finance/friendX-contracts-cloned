// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { Script, console2 } from "forge-std/Script.sol";

import { FanToken } from "../src/FanToken.sol";

function upgradeFanToken(FanToken fanToken) {
    console2.log("fanToken: %s to be upgraded", address(fanToken));
    FanToken newFanTokenLogic = new FanToken();
    console2.log("--> newFanTokenLogic: %s", address(newFanTokenLogic));
    fanToken.upgradeTo(address(newFanTokenLogic));
    console2.log("fanToken ugpraded...");
}

contract UpgradeFanTokenLogicScript is Script {
    function _startBroadcast() internal {
        uint256 deployerPrivKey = vm.envOr("PRIVKEY", uint256(0));
        _showGitRevision();

        console2.log("Deployer address", msg.sender);

        // Setup deployment account, using private key from environment variable or foundry keystore (`cast wallet`).
        if (deployerPrivKey != 0) {
            vm.startBroadcast(deployerPrivKey);
        } else {
            vm.startBroadcast();
        }
    }

    function _stopBroadcast() internal {
        vm.stopBroadcast();
    }

    function _showGitRevision() internal {
        string[] memory inputs = new string[](1);
        inputs[0] = "../../tasks/show-git-rev.sh";
        try vm.ffi(inputs) returns (bytes memory res) {
            console2.log("Git revision: %s", string(res));
        } catch {
            console2.log("!! _showGitRevision: FFI not enabled");
        }
    }

    function run() public {
        _startBroadcast();
        upgradeFanToken(FanToken(vm.envAddress("ALFA_TOKEN")));
        _stopBroadcast();
    }

}
