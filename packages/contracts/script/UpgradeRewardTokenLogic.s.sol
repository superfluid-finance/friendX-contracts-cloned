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
// forge script script/UpgradeRewardTokenLogic.s.sol:UpgradeRewardTokenLogicScript --rpc-url $RPC_URL --broadcast --verify -vvvv

/// @title UpgradeRewardTokenLogicScript
/// @notice This script is used to upgrade the RewardToken logic contract
/// @dev    A script to upgrade the RewardToken logic contract
///         the Channel Beacon logic contract does not need to be upgraded
///         because we are pointing at the RewardToken proxy in the Channel contract
contract UpgradeRewardTokenLogicScript is Script {
    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Channel contract constructor params
        ISuperfluid host = ISuperfluid(vm.envAddress("HOST_ADDRESS"));
        ISETH ethX = ISETH(vm.envAddress("SUBSCRIPTION_SUPER_TOKEN_ADDRESS"));
        address protocolFeeDest = vm.envAddress("PROTOCOL_FEE_DEST");
        FanToken rewardToken = FanToken(vm.envAddress("REWARD_TOKEN_PROXY_ADDRESS"));

        FanToken newRewardTokenLogic = new FanToken();

        rewardToken.upgradeTo(address(newRewardTokenLogic));
    }
}
