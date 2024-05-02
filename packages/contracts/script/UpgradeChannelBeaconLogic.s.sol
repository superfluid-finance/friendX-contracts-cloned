// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { Script, console2 } from "forge-std/Script.sol";
import { ISETH, ISuperfluid } from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { ChannelFactory } from "../src/ChannelFactory.sol";
import { Channel } from "../src/Channel.sol";

// To run:
// forge script script/UpgradeChannelBeaconLogic.s.sol:UpgradeChannelBeaconLogicScript --rpc-url $RPC_URL --broadcast --verify -vvvv

/// @title UpgradeChannelBeaconLogicScript
/// @notice This script is used to upgrade the channel beacon logic contract
/// @dev A script to upgrade the channel beacon logic contract
contract UpgradeChannelBeaconLogicScript is Script {
    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Channel contract constructor params
        ISuperfluid host = ISuperfluid(vm.envAddress("HOST_ADDRESS"));
        ISETH ethX = ISETH(vm.envAddress("SUBSCRIPTION_SUPER_TOKEN_ADDRESS"));
        address protocolFeeDest = vm.envAddress("PROTOCOL_FEE_DEST");
        FanToken rewardToken = FanToken(vm.envAddress("REWARD_TOKEN_PROXY_ADDRESS"));

        // deploy the new channel logic contract and initialize it so it cannot be initialized arbitrarily
        Channel channelLogic = new Channel(host, protocolFeeDest, ethX, rewardToken);
        address channelLogicAddress = address(channelLogic);

        // upgrade the channel beacon logic contract
        ChannelFactory channelFactory = ChannelFactory(vm.envAddress("CHANNEL_FACTORY_ADDRESS"));
        UpgradeableBeacon beacon = channelFactory.CHANNEL_BEACON();
        beacon.upgradeTo(channelLogicAddress);
    }

}
