// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { Channel, ChannelBase } from "../src/Channel.sol";
import { upgradeFanToken } from "../script/UpgradeFanTokenLogic.s.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {ISuperToken} from "../lib/superfluid-protocol-monorepo/packages/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import  "../src/BatchOperationHelpers.sol";


contract FanTokenForkRewardsTest is Test {
    using SuperTokenV1Library for ISuperToken;

    address constant DEPLOYER = 0xc33539b3cA1923624762E8a42D699806C865D652;
    FanToken constant ALFA_TOKEN = FanToken(0x905Cf6aDF9510EE12C78dD9c6A5445320db24342);

    ChannelBase large_channel = ChannelBase(0x35594aCfed507027A32D7D05dC77015703A1bb8C);
    //ChannelBase medium_channel = ChannelBase(0x6bB194B440e485d1CfF40F7d4194bcBd97411EfD);
    //ChannelBase small_channel = ChannelBase(0x9d9141d98ea1B553A8D761C23C221603Bd58a58b);
    ChannelBase medium_channel = ChannelBase(0xdba348c9F8dcac041864cD6ed818B1C0490a32c6); //agustins channel
    ChannelBase small_channel = ChannelBase(0xE316Fc194A2Bf5774C915484A3400a08Eb8743F6); // elvijs channel
    address constant vijay_aa = 0xd6f6663035B4DDcDb4Cd18981501985077dF484D;

    uint256 fork;
    uint256 fork_block_number;

    function setUp() public {
        fork = vm.createFork(vm.envString("FOUNDRY_ETH_RPC_URL"));
        fork_block_number = vm.getBlockNumber();
    }

    function _setUpNewFanToken() public {
        console2.log("fanToken: %s to be upgraded", address(0x905Cf6aDF9510EE12C78dD9c6A5445320db24342));
        FanToken newFanTokenLogic = new FanToken();
        console2.log("--> newFanTokenLogic: %s", address(newFanTokenLogic));
        vm.startPrank(DEPLOYER);
        ALFA_TOKEN.upgradeTo(address(newFanTokenLogic));
        ALFA_TOKEN.setLoyaltyBonus(20000, 60 days);
        ALFA_TOKEN.setFlowBasedRewardBase(20714); // constant setting
        console2.log("fanToken ugpraded...");

        // check if the upgrade was successful
        console2.log("fanToken: %s", address(ALFA_TOKEN));
        console2.log("fanToken owner: %s", ALFA_TOKEN.owner());
        console2.log("fanToken loyaltyBonus: %s", ALFA_TOKEN.loyaltyBonusMultiplier());
        console2.log("fanToken loyaltyBonusDuration: %s", ALFA_TOKEN.loyaltyBonusPeriodUntilFull());
        console2.log("fanToken flowBaseRewardFactor: %s", ALFA_TOKEN.flowBasedRewardBase());
    }

    modifier rollback {
        _;
        vm.rollFork(fork, fork_block_number);
    }

    function testRunNewRewardsFreshStreams() rollback external {

        vm.startPrank(vijay_aa);
        // close vijay streams
        ISuperToken token = ISuperToken(large_channel.SUBSCRIPTION_SUPER_TOKEN());
        token.deleteFlow(vijay_aa, address(large_channel));
        token.deleteFlow(vijay_aa, address(medium_channel));
        token.deleteFlow(vijay_aa, address(small_channel));
        vm.warp(block.timestamp + 1 days);

        // open new streams
        _helperSubscribeToChannel(token, vijay_aa, address(large_channel), large_channel.subscriptionFlowRate());
        _helperSubscribeToChannel(token, vijay_aa, address(medium_channel), medium_channel.subscriptionFlowRate());
        _helperSubscribeToChannel(token, vijay_aa, address(small_channel), small_channel.subscriptionFlowRate());

        vm.stopPrank();
        uint256 now = block.timestamp;
        //vm.warp(now);
        {
            console2.log("large_channel_flow_rate (totalInflowRate) : ", large_channel.totalInflowRate());
            console2.log("medium_channel_flow_rate (totalInflowRate) : ", medium_channel.totalInflowRate());
            console2.log("small_channel_flow_rate (totalInflowRate) : ", small_channel.totalInflowRate());

            console2.log("large_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(large_channel)));
            console2.log("medium_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(medium_channel)));
            console2.log("small_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(small_channel)));
        }

        (, int96 vijay_to_large) = large_channel.getSubscriberFlowInfo(vijay_aa);
        (, int96 vijay_to_medium) = medium_channel.getSubscriberFlowInfo(vijay_aa);
        (, int96 vijay_to_small) = small_channel.getSubscriberFlowInfo(vijay_aa);
        {
            console2.log("vijay_to_large : ", vijay_to_large);
            console2.log("vijay_to_medium : ", vijay_to_medium);
            console2.log("vijay_to_small : ", vijay_to_small);
        }

        console2.log("Total Subscription InflowRate(): ", uint256(ALFA_TOKEN.totalSubscriptionInflowRate()));
        console2.log("Total Staked: ", ALFA_TOKEN.totalStaked());

        uint256[3][71] memory rewardsBefore;
        uint256[3][71] memory rewardsAfter;

        uint256 t = now;
        for (uint256 i = 0; i < 71; i++) {
            rewardsBefore[i][0] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(large_channel));
            //rewardsBefore[i][1] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(medium_channel));
            //rewardsBefore[i][2] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(small_channel));
            t += (1 days);
            vm.warp(t);
        }

        vm.rollFork(fork, fork_block_number);

        _setUpNewFanToken();
        t = now;
        for(uint256 i = 0; i < 71; i++) {

            rewardsAfter[i][0] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(large_channel));
            //rewardsAfter[i][1] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(medium_channel));
            //rewardsAfter[i][2] = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(small_channel));
            t += 1 days;
            vm.warp(t);
        }

        console2.log("---");
        console2.log("Week\tRewards Before\tRewards After\t% Diff");
        console2.log("For Large Channel (", address(large_channel), ")");
        for (uint256 i = 1; i < 71; i++) {
            uint256 diffLarge = rewardsAfter[i][0] > rewardsBefore[i][0] ?
                ((rewardsAfter[i][0] - rewardsBefore[i][0]) * 10000) / rewardsBefore[i][0] : 0;
            console2.log(string(abi.encodePacked(
                uint2str(i), "\t",
                uint2str(rewardsBefore[i][0]), "\t",
                uint2str(rewardsAfter[i][0]), "\t",
                uint2str(diffLarge / 100), ".", uint2str(diffLarge % 100), "%"
            )));
        }
    }

    function testFlowBaseRewardComponent() public rollback {

        vm.startPrank(vijay_aa);
        ISuperToken token = ISuperToken(large_channel.SUBSCRIPTION_SUPER_TOKEN());
        vm.stopPrank();
        uint256 now = block.timestamp;
        vm.warp(now);
        {
            console2.log("large_channel_flow_rate (totalInflowRate) : ", large_channel.totalInflowRate());
            console2.log("medium_channel_flow_rate (totalInflowRate) : ", medium_channel.totalInflowRate());
            console2.log("small_channel_flow_rate (totalInflowRate) : ", small_channel.totalInflowRate());
            console2.log("large_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(large_channel)));
            console2.log("medium_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(medium_channel)));
            console2.log("small_channel_total_staked: ", ALFA_TOKEN.channelStakedBalanceOf(address(small_channel)));
            console2.log("Total Subscription InflowRate(): ", uint256(ALFA_TOKEN.totalSubscriptionInflowRate()));
            console2.log("Total Staked: ", ALFA_TOKEN.totalStaked());
        }

        uint256 large_channel_reward_before = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(large_channel));
        uint256 medium_channel_reward_before = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(medium_channel));
        uint256 small_channel_reward_before = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(small_channel));

        vm.rollFork(fork, fork_block_number);
        _setUpNewFanToken();
        uint256 large_channel_reward_after = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(large_channel));
        uint256 medium_channel_reward_after = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(medium_channel));
        uint256 small_channel_reward_after = ALFA_TOKEN.getClaimableAmount(vijay_aa, address(small_channel));
        console2.log("--- LARGE CHANNEL --- (", address(large_channel), ")");
        console2.log("Rewards Before\tRewards After");
        console2.log(string(abi.encodePacked(uint2str(large_channel_reward_before), "\t",uint2str(large_channel_reward_after))));
        console2.log("--- MEDIUM CHANNEL --- (", address(medium_channel), ")");
        console2.log("Rewards Before\tRewards After");
        console2.log(string(abi.encodePacked(uint2str(medium_channel_reward_before), "\t",uint2str(medium_channel_reward_after))));
        console2.log("--- SMALL CHANNEL --- (", address(small_channel), ")");
        console2.log("Rewards Before\tRewards After");
        console2.log(string(abi.encodePacked(uint2str(small_channel_reward_before), "\t",uint2str(small_channel_reward_after))));
    }

    function uint2str(uint _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len;
        while (_i != 0) {
            k = k-1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function _helperSubscribeToChannel(ISuperToken token, address subscriber, address channelInstance, int96 flowRate)
    internal
    {
        flowRate = int96(bound(flowRate, int96(0.05 ether) / int96(30 days), int96(1e15)));
        ChannelBase channel = ChannelBase(channelInstance);
        ISuperfluid host = channel.HOST();

        {
            ISuperfluid.Operation[] memory ops =
                            getSubscribeBatchOperation(host, token, channelInstance, flowRate);

            vm.startPrank(subscriber);
            host.batchCall(ops);
            vm.stopPrank();
        }
    }

}
