// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { upgradeFanToken } from "../script/UpgradeFanTokenLogic.s.sol";

contract fanTokenForkTest is Test {
    address constant DEPLOYER = 0xc33539b3cA1923624762E8a42D699806C865D652;
    FanToken constant ALFA_TOKEN = FanToken(0x905Cf6aDF9510EE12C78dD9c6A5445320db24342);
    address constant VIJAY_CHANNEL = 0xfC9cf3C67c2AAa891f4d727fa26f945A6d63AD65;
    address constant ELVIJS_CHANNEL = 0xE316Fc194A2Bf5774C915484A3400a08Eb8743F6;
    address constant ELVIJS_AA = 0xCeDF538EEeEB6Cd2a07668b89FD2B9675cdb52A1;
    address constant VIJAY_AA = 0xd6f6663035B4DDcDb4Cd18981501985077dF484D;

    uint256 fork;

    function setUp() public {
        fork = vm.createFork(vm.envString("FOUNDRY_ETH_RPC_URL"));
        
    }

    function testOnlyOwnerUpgrade() external {
        vm.expectRevert(IFanToken.FAN_TOKEN_ONLY_OWNER.selector);
        this._stubUpgradeFanToken();
    }

    function _stubUpgradeFanToken() external {
        upgradeFanToken(ALFA_TOKEN);
    }

    function testPlotVijayChannelRewards() external {
        uint256 newRewardDurationInWeeks = 24;
        uint256 t0 = block.timestamp;
        console2.log("Reward emissions before and after ALFA upgrade (Vijay Channel)");
        _collectAndDisplayRewards(
            t0,
            ELVIJS_AA,
            VIJAY_CHANNEL,
            1 weeks,
            newRewardDurationInWeeks,
            _operationToTest
        );
    }

    function testPlotElvijsChannelRewards() external {
        uint256 newRewardDurationInWeeks = 24;
        uint256 t0 = block.timestamp;
        console2.log("Reward emissions before and after ALFA upgrade (Elvijs Channel)");
        _collectAndDisplayRewards(
            t0,
            VIJAY_AA,
            ELVIJS_CHANNEL,
            1 weeks,
            newRewardDurationInWeeks,
            _operationToTest
        );
    }

    function _operationToTest() internal {
        vm.startPrank(DEPLOYER);
        upgradeFanToken(ALFA_TOKEN);
        ALFA_TOKEN.setRewardDuration(520 * 1 weeks);
        vm.stopPrank();
    }

    function _collectAndDisplayRewards(
        uint256 t0,
        address subscriber,
        address channel,
        uint256 stepSize,
        uint256 nSteps,
        function() internal operation
    ) internal {

        uint256[] memory rewardsBefore = new uint256[](nSteps);
        uint256[] memory rewardsAfter = new uint256[](nSteps);

        _collectChannelRewards(t0, subscriber, channel, stepSize, rewardsBefore);
        operation();
        _collectChannelRewards(t0, subscriber, channel, stepSize, rewardsAfter);
        console2.log("---");
        console2.log("Week\tRewards Before\tRewards After");
        for (uint256 i = 0; i < rewardsBefore.length; i++) {
            console2.log("%d\t%e\t%e", i, rewardsBefore[i], rewardsAfter[i]);
        }
        console2.log("---");
        uint256 sumBefore = 0;
        uint256 sumAfter = 0;
        for (uint256 i = 0; i < nSteps; i++) {
            sumBefore += rewardsBefore[i];
            sumAfter += rewardsAfter[i];
        }
        console2.log("Sum\t%e\t%e", sumBefore, sumAfter);
    }

    function _collectChannelRewards(
        uint256 t0,
        address subscriber,
        address channel,
        uint256 stepSize,
        uint256[] memory rewards // implictly passed by reference because is internal call, why not...
    ) internal {
        for (uint256 i = 0; i < rewards.length; i++) {
            vm.warp(t0 + i * stepSize);
            rewards[i] = ALFA_TOKEN.getDailyMaxClaimableAmount(subscriber, channel);
        }
    }
}
