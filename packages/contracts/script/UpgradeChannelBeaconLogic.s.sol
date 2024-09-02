// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { Script, console2 } from "forge-std/Script.sol";
import {
    ISETH, ISuperfluid
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { ChannelFactory } from "../src/ChannelFactory.sol";
import { Channel } from "../src/Channel.sol";

// To run:
// forge script script/UpgradeChannelBeaconLogic.s.sol:UpgradeChannelBeaconLogicScript --rpc-url $RPC_URL --broadcast --verify -vvvv

function upgradeChannel(ChannelFactory channelFactory) returns (Channel oldImpl, Channel newImpl) {
    console2.log("channelFactory %s", address(channelFactory));
    UpgradeableBeacon beacon = channelFactory.CHANNEL_BEACON();
    console2.log("  beacon %s", address(beacon));

    oldImpl = Channel(beacon.implementation());
    console2.log("  oldImpl %s", address(oldImpl));
    console2.log("    HOST %s", address(oldImpl.HOST()));
    console2.log("    SUBSCRIPTION_SUPER_TOKEN %s", address(oldImpl.SUBSCRIPTION_SUPER_TOKEN()));
    console2.log("    FAN %s", address(oldImpl.FAN()));
    console2.log("    PROTOCOL_FEE_DESTINATION %s", address(oldImpl.PROTOCOL_FEE_DESTINATION()));
    console2.log("    PROTOCOL_FEE_AMOUNT %d", oldImpl.PROTOCOL_FEE_AMOUNT());

    newImpl = new Channel(oldImpl.HOST(),
                          oldImpl.SUBSCRIPTION_SUPER_TOKEN(), oldImpl.FAN(),
                          oldImpl.PROTOCOL_FEE_DESTINATION(), oldImpl.PROTOCOL_FEE_AMOUNT(),
                          /* TODO hard-coded min/max SubscriptionFlowRate */
                          int96(490e18) / 30 days, int96(1500e18) / 30 days);
    console2.log("  newImpl %s", address(newImpl));
    console2.log("    HOST %s", address(newImpl.HOST()));
    console2.log("    SUBSCRIPTION_SUPER_TOKEN %s", address(newImpl.SUBSCRIPTION_SUPER_TOKEN()));
    console2.log("    FAN %s", address(newImpl.FAN()));
    console2.log("    PROTOCOL_FEE_DESTINATION %s", address(newImpl.PROTOCOL_FEE_DESTINATION()));
    console2.log("    PROTOCOL_FEE_AMOUNT %d", newImpl.PROTOCOL_FEE_AMOUNT());
    console2.log("    CHANNEL_POOL_SCALING_FACTOR %d", newImpl.CHANNEL_POOL_SCALING_FACTOR());
    console2.log("    CHANNEL_POOL_SCALING_FACTOR_R0 %d", newImpl.CHANNEL_POOL_SCALING_FACTOR_R0());
    console2.log("    CHANNEL_POOL_SCALING_FACTOR_R1 %d", newImpl.CHANNEL_POOL_SCALING_FACTOR_R1());

    beacon.upgradeTo(address(newImpl));
}

/// @title UpgradeChannelBeaconLogicScript
/// @notice This script is used to upgrade the channel beacon logic contract
/// @dev A script to upgrade the channel beacon logic contract
contract UpgradeChannelBeaconLogicScript is Script {
    function setUp() public { }

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
        upgradeChannel(ChannelFactory(vm.envAddress("CHANNEL_FACTORY_ADDRESS")));
        _stopBroadcast();
    }

}
