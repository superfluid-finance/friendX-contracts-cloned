// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MANDATORY_CREATOR_FEE_PCT } from "../src/ChannelFactory.sol";
import { ChannelBase } from "../src/interfaces/ChannelBase.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { SFTest } from "./SFTest.t.sol";


contract FanTokenStorageLayoutTest is FanToken {
    function testStorageLayout() external pure {
        uint256 slot;
        uint256 offset;

        //   0 ..   0  | Initializable      | uint8 _initialized; bool _initialized;
        //   1 ..  50  | ContextUpgradeable | uint256[50] __gap;
        //  51 .. 100  | ERC20Upgradeable   | 50 slots;

        // FanToken storages

        assembly { slot:= _subscriberCreatorChannelData.slot offset := _subscriberCreatorChannelData.offset }
        require(slot == 101 && offset == 0, "_subscriberCreatorChannelData changed location");

        assembly { slot:= _channelStakedBalances.slot offset := _channelStakedBalances.offset }
        require(slot == 102 && offset == 0, "_channelStakedBalances changed location");

        assembly { slot:= _subscriberData.slot offset := _subscriberData.offset }
        require(slot == 103 && offset == 0, "_subscriberData changed location");

        assembly { slot:= totalStaked.slot offset := totalStaked.offset }
        require(slot == 104 && offset == 0, "totalStaked changed location");

        assembly { slot:= totalSubscriptionInflowRate.slot offset := totalSubscriptionInflowRate.offset }
        require(slot == 105 && offset == 0, "totalSubscriptionInflowRate changed location");

        assembly { slot:= channelFactory.slot offset := channelFactory.offset }
        require(slot == 106 && offset == 0, "channelFactory changed location");

        assembly { slot:= owner.slot offset := owner.offset }
        require(slot == 107 && offset == 0, "owner changed location");

        assembly { slot:= startTime.slot offset := startTime.offset }
        require(slot == 108 && offset == 0, "startTime changed location");

        assembly { slot:= rewardDuration.slot offset := rewardDuration.offset }
        require(slot == 109 && offset == 0, "rewardDuration changed location");

        assembly { slot:= multiplier.slot offset := multiplier.offset }
        require(slot == 110 && offset == 0, "multiplier changed location");

        assembly { slot:= flowBasedRewardsPercentage.slot offset := flowBasedRewardsPercentage.offset }
        require(slot == 111 && offset == 0, "flowBasedRewardsPercentage changed location");

        assembly { slot:= stakedBasedRewardsPercentage.slot offset := stakedBasedRewardsPercentage.offset }
        require(slot == 112 && offset == 0, "stakedBasedRewardsPercentage changed location");
    }
}

contract FanTokenTest is SFTest {
    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    int96   internal constant FLOW_RATE = int96(1000e18) / 30 days; // 385802469135802
    uint256 internal constant CREATOR_FEE_PERCENTAGE = MANDATORY_CREATOR_FEE_PCT;
    uint256 FLOW_BASED_REWARD_BASE = 20714;

    function setUp() public override {
        super.setUp();
        // deal some FAN to ALICE for testing
        _mintFanTokens(ALICE, _stakingAmount(1e6));

        // start at a more realistic timestamp than 0 because of
        // the cooldown modifier logic
        vm.warp(block.timestamp + 60 days);

        // set loyalty bonusA
        vm.startPrank(fanToken.owner());
        fanToken.setLoyaltyBonus(30000, 60 days);
        fanToken.setFlowBasedRewardBase(FLOW_BASED_REWARD_BASE);
        vm.stopPrank();
    }

    function testRevertIfTransfer() public {
        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_TRANSFER_DISABLED.selector);
        fanToken.transfer(BOB, 1);
        vm.stopPrank();
    }

    function testRevertIfTransferFrom() public {
        vm.startPrank(ALICE);
        fanToken.approve(BOB, 1);
        vm.stopPrank();

        vm.startPrank(BOB);
        vm.expectRevert(IFanToken.FAN_TOKEN_TRANSFER_DISABLED.selector);
        fanToken.transferFrom(ALICE, BOB, 1);
        vm.stopPrank();
    }

    //// initialize ////
    function testRevertIfInitializeCalledDirectly() public {
        FanToken fanTokenLocal = new FanToken();
        vm.expectRevert("Initializable: contract is already initialized");
        fanTokenLocal.initialize(ALICE, 1 weeks, 20000, 3100, 6900);
    }

    function testInitializeViaProxy() public {
        FanToken fanTokenLocal = new FanToken();
        address fanTokenProxyAddress = address(new ERC1967Proxy(address(fanTokenLocal), ""));
        FanToken fanTokenProxy = FanToken(fanTokenProxyAddress);

        fanTokenProxy.initialize(ALICE, 1 weeks, 20000, 3100, 6900);
        assertEq(fanTokenProxy.owner(), ALICE, "testInitializeViaProxy: owner should be ALICE");
    }

    //// setOwner ////
    function testRevertIfSetOwnerAsNotOwner() public {
        vm.expectRevert(IFanToken.FAN_TOKEN_ONLY_OWNER.selector);
        fanToken.setOwner(BOB);
    }

    function testOwnerCanSetOwner() public {
        vm.startPrank(fanToken.owner());
        fanToken.setOwner(BOB);
        vm.stopPrank();
    }

    //// setChannelFactory ////
    function testRevertIfNonOwnerCallsSetChannelFactory() public {
        vm.expectRevert(IFanToken.FAN_TOKEN_ONLY_OWNER.selector);
        fanToken.setChannelFactory(address(channelFactory));
    }

    function testOwnerCanCallSetChannelFactory() public {
        vm.startPrank(fanToken.owner());
        fanToken.setChannelFactory(address(channelFactory));
        vm.stopPrank();
    }

    function testOwnerCanSetRewardDuration() public {
        vm.startPrank(fanToken.owner());
        uint256 oldRewardDuration = fanToken.rewardDuration();
        fanToken.setRewardDuration(oldRewardDuration + 180 days);

        assertEq(
            fanToken.rewardDuration(),
            oldRewardDuration + 180 days,
            "testOwnerCanSetRewardDuration: reward duration should be updated"
        );
        vm.stopPrank();
    }

    function testNotOwnerCannotSetRewardDuration() public {
        vm.expectRevert(IFanToken.FAN_TOKEN_ONLY_OWNER.selector);
        fanToken.setRewardDuration(180 days);
    }

    function testOwnerCanSetLoyaltyMultiplierAndPeriod() public {
        vm.startPrank(fanToken.owner());
        fanToken.setLoyaltyBonus(20000, 60 days);
        assertEq(
            fanToken.loyaltyBonusMultiplier(),
            20000,
            "testOwnerCanSetLoyaltyMultiplierAndPeriod: loyalty bonus multiplier should be updated"
        );

        assertEq(
            fanToken.loyaltyBonusPeriodUntilFull(),
            60 days,
            "testOwnerCanSetLoyaltyMultiplierAndPeriod: loyalty bonus period should be updated"
        );
        vm.stopPrank();
    }

    function testNotOwnerCannotSetLoyaltyMultiplierAndPeriod() public {
        vm.expectRevert(IFanToken.FAN_TOKEN_ONLY_OWNER.selector);
        fanToken.setLoyaltyBonus(20000, 60 days);
    }

    //// stake ////
    function testRevertIfStakeToInvalidCreatorChannel(address notCreatorChannel, uint256 stakeAmount) public {
        vm.expectRevert(IFanToken.FAN_TOKEN_INVALID_CREATOR_CHANNEL.selector);
        fanToken.stake(notCreatorChannel, stakeAmount);
    }

    function testRevertIfStakeWithInsufficientFANTokenBalamce() public {
        address channelInstance = _helperCreateChannelContract(ALICE, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        vm.startPrank(BOB);
        vm.expectRevert(IFanToken.FAN_TOKEN_INSUFFICIENT_FAN_BALANCE.selector);
        fanToken.stake(channelInstance, 1);
        vm.stopPrank();
    }

    function testRevertIfStakeWithOngoingUnstakeCooldown(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + 24 hours);

        console.log("stakedBalanceOf", fanToken.stakedBalanceOf(ALICE, channelInstance));
        console.log("fanAmount", fanToken.balanceOf(ALICE));

        _helperClaim(ALICE, channelInstance);
        console.log("stakedBalanceOf", fanToken.stakedBalanceOf(ALICE, channelInstance));
        console.log("fanAmount", fanToken.balanceOf(ALICE));

        _helperStake(ALICE, channelInstance, _stakingAmount(100));
        console.log("stakedBalanceOf", fanToken.stakedBalanceOf(ALICE, channelInstance));
        console.log("fanAmount", fanToken.balanceOf(ALICE));

        _helperUnstake(ALICE, channelInstance, _stakingAmount(100));
        console.log("stakedBalanceOf", fanToken.stakedBalanceOf(ALICE, channelInstance));
        console.log("fanAmount", fanToken.balanceOf(ALICE));

        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER.selector);
        fanToken.stake(channelInstance, 1);
        vm.stopPrank();
    }

    // function testRevertIfStakeWithNoFlow() public {
    //     address channelInstance = _helperCreateChannelContract(ALICE, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
    //     vm.startPrank(ALICE);
    //     vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
    //     fanToken.stake(channelInstance, 100);
    //     vm.stopPrank();
    // }

    function testStakeToSingleCreatorChannel(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(ALICE, channelInstance, _stakingAmount(100));
    }

    function testStakeToOwnChannel(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(ALICE, channelInstance, _stakingAmount(100));
    }

    function testStakeToMultipleCreatorChannels(int96 flowRate) public {
        _mintFanTokens(BOB, _stakingAmount(200));

        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, CREATOR_FEE_PERCENTAGE);
        address carolChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(CAROL, BOB, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(BOB, aliceChannelAddress, _stakingAmount(100));
        _helperStake(BOB, carolChannelAddress, _stakingAmount(100));
    }

    function testStakeAgainAfterUnstakeCooldown(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + 24 hours);

        _helperClaim(ALICE, channelInstance);

        _helperStake(ALICE, channelInstance, _stakingAmount(100));

        _helperUnstake(ALICE, channelInstance, _stakingAmount(100));

        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD() + 1);

        _helperStake(ALICE, channelInstance, _stakingAmount(100));
    }

    //// unstake ////
    function testRevertIfUnstakeToInvalidChannelCreator(address notCreatorChannel, uint256 stakeAmount) public {
        vm.expectRevert(IFanToken.FAN_TOKEN_INVALID_CREATOR_CHANNEL.selector);
        fanToken.unstake(notCreatorChannel, stakeAmount);
    }

    function testRevertIfUnstakeWithInsufficientStakedFANBalance() public {
        address channelInstance = _helperCreateChannelContract(ALICE, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_INSUFFICIENT_STAKED_FAN_BALANCE.selector);
        fanToken.unstake(channelInstance, 1);
        vm.stopPrank();
    }

    function testUnstake() public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(BOB, BOB, 3805175038, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + 24 hours);

        _helperClaim(BOB, channelInstance);

        uint256 balance = fanToken.balanceOf(BOB);

        // stake some FAN
        _helperStake(BOB, channelInstance, balance);

        // unstake half of the staked FAN
        _helperUnstake(BOB, channelInstance, balance);
    }

    function testUnstakeAgainAfterUnstakeCooldown(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN to alice channel
        _helperStake(ALICE, aliceChannelAddress, _stakingAmount(100));

        // stake some FAN to bob channel
        _helperStake(ALICE, bobChannelAddress, _stakingAmount(100));

        // stake some FAN to alice
        _helperUnstake(ALICE, aliceChannelAddress, _stakingAmount(50));

        // warp till unstake cooldown is over
        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD() + 1);

        // unstake again
        _helperUnstake(ALICE, bobChannelAddress, _stakingAmount(50));
    }

    //// claim ////
    function testRevertIfClaimFromInvalidCreatorChannel(address notCreatorChannel) public {
        vm.expectRevert(IFanToken.FAN_TOKEN_INVALID_CREATOR_CHANNEL.selector);
        fanToken.claim(notCreatorChannel);
    }

    function testClaim(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // claim
        _helperClaim(ALICE, channelInstance);
    }

    function testClaimAfter12HoursGivesHalfTheAmount(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        assertEq(
            fanToken.getClaimableAmount(ALICE, channelInstance),
            0,
            "testClaimAfter24HoursStillGivesSameAmount: claimable amount should be 0"
        );

        vm.warp(block.timestamp + 12 hours);

        // 24 hours worth of rewards - the user is the only member of the channel
        uint256 expectedClaimableAmount = fanToken.getDailyMaxClaimableAmount(ALICE, channelInstance) / 2;

        assertEq(
            fanToken.getClaimableAmount(ALICE, channelInstance),
            expectedClaimableAmount,
            "testClaimAfter24HoursStillGivesSameAmount: claimable amount should be equal to max"
        );

        // claim
        _helperClaim(ALICE, channelInstance);
    }

    function testClaimAfter24HoursStillGivesSameAmount(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        assertEq(
            fanToken.getClaimableAmount(ALICE, channelInstance),
            0,
            "testClaimAfter24HoursStillGivesSameAmount: claimable amount should be 0"
        );

        vm.warp(block.timestamp + 25 hours);

        // 24 hours worth of rewards - the user is the only member of the channel
        uint256 expectedClaimableAmount = fanToken.getDailyMaxClaimableAmount(ALICE, channelInstance);

        assertEq(
            fanToken.getClaimableAmount(ALICE, channelInstance),
            expectedClaimableAmount,
            "testClaimAfter24HoursStillGivesSameAmount: claimable amount should be equal to max"
        );

        // claim
        _helperClaim(ALICE, channelInstance);
    }

    //// compound ////
    function testRevertIfCompoundToInvalidCreatorChannel(address notCreatorChannel) public {
        vm.expectRevert(IFanToken.FAN_TOKEN_INVALID_CREATOR_CHANNEL.selector);
        fanToken.compound(notCreatorChannel);
    }

    function testRevertIfCompoundWithOngoingUnstakeCooldown(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(ALICE, channelInstance, _stakingAmount(100));

        _helperUnstake(ALICE, channelInstance, _stakingAmount(50));

        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER.selector);
        fanToken.compound(channelInstance);
        vm.stopPrank();
    }

    function testCompound(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD());

        // compound
        _helperCompound(ALICE, channelInstance);
    }

    function testCompoundAgainAfterUnstakeCooldown(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN
        _helperStake(ALICE, aliceChannelAddress, _stakingAmount(100));

        // unstake some FAN
        _helperUnstake(ALICE, aliceChannelAddress, _stakingAmount(50));

        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD() + 1);

        // compound again
        _helperCompound(ALICE, aliceChannelAddress);
    }

    //// claimAll ////

    function testClaimAllWithOngoingUnstakeCooldown(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN
        _helperStake(ALICE, aliceChannelAddress, _stakingAmount(100));
        _helperStake(ALICE, bobChannelAddress, _stakingAmount(100));

        _helperUnstake(ALICE, aliceChannelAddress, 50);

        address[] memory channelAddresses = new address[](2);
        channelAddresses[0] = aliceChannelAddress;
        channelAddresses[1] = bobChannelAddress;

        // claim all
        vm.startPrank(ALICE);
        fanToken.claimAll(channelAddresses);
        vm.stopPrank();
    }

    function testClaimAllSimple(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN
        _helperStake(ALICE, aliceChannelAddress, _stakingAmount(100));
        _helperStake(ALICE, bobChannelAddress, _stakingAmount(100));

        address[] memory channelAddresses = new address[](2);
        channelAddresses[0] = aliceChannelAddress;
        channelAddresses[1] = bobChannelAddress;

        // claim all
        vm.startPrank(ALICE);
        fanToken.claimAll(channelAddresses);
        vm.stopPrank();
    }

    // //// compoundAll ////

    function testRevertIfCompoundAllWithOngoingUnstakeCooldown(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN
        _helperStake(ALICE, aliceChannelAddress, _stakingAmount(100));
        _helperStake(ALICE, bobChannelAddress, _stakingAmount(100));

        _helperUnstake(ALICE, aliceChannelAddress, _stakingAmount(50));

        address[] memory channelAddresses = new address[](2);
        channelAddresses[0] = aliceChannelAddress;
        channelAddresses[1] = bobChannelAddress;

        // compound all
        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER.selector);
        fanToken.compoundAll(channelAddresses);
        vm.stopPrank();
    }

    function testCompoundAll(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD());

        address[] memory channelAddresses = new address[](2);
        channelAddresses[0] = aliceChannelAddress;
        channelAddresses[1] = bobChannelAddress;

        // compound all
        vm.startPrank(ALICE);
        fanToken.compoundAll(channelAddresses);
        vm.stopPrank();
    }

    //// getTotalRewardsDistribution ////

    function testTotalRewardsDistributionIsZeroWhenNoInflows() public view {
        assertEq(
            fanToken.getTotalRewardsDistribution(),
            0,
            "testTotalRewardsDistributionIsZeroWhenNoInflows: total rewards distribution should be zero"
        );
    }

    function testTotalRewardsDistributionWhenNoStakedBalanceUsesInflowRate(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // we need to get the actual flowRate here because the param flowRate is not the actual
        // vm.assume'd final flow rate
        (uint256 lastUpdated, int96 actualFlowRate,,) = _sf.cfa.getFlow(_subscriptionSuperToken, ALICE, aliceChannelAddress);
        uint256 TOTAL_REWARDS = uint96(actualFlowRate) * fanToken.multiplier() / ONE_HUNDRED_PERCENT;
        uint256 LOYALTY_BONUS_MULTIPLIER = fanToken.loyaltyBonusMultiplier();
        uint256 LOYALTY_BONUS_PERIOD = fanToken.loyaltyBonusPeriodUntilFull();
        uint256 streamDuration = block.timestamp - lastUpdated;
        uint256 loyaltyBonus = 0;
        if(streamDuration < LOYALTY_BONUS_PERIOD) {
            TOTAL_REWARDS += (TOTAL_REWARDS * LOYALTY_BONUS_MULTIPLIER * streamDuration / LOYALTY_BONUS_PERIOD) / ONE_HUNDRED_PERCENT;
        } else {
            TOTAL_REWARDS += TOTAL_REWARDS * LOYALTY_BONUS_MULTIPLIER / ONE_HUNDRED_PERCENT;
        }
        uint256 totalRewardsDistribution =  fanToken.getTotalRewardsDistribution();
        uint256 rounding = TOTAL_REWARDS - totalRewardsDistribution;
        assertLt(
            rounding,
            2,
            "testTotalClaimableAmountIsExpectedWithInflows: rounding should be less than 2"
        );

        assertEq(
            fanToken.getTotalRewardsDistribution(),
            TOTAL_REWARDS,
            "testTotalRewardsDistributionWhenNoStakedBalanceUsesInflowRate: total rewards distribution should be equal to inflow rate"
        );
    }

    //// getClaimableAmount ////

    function testClaimableAmountIsZeroWhenNoInflows() public {
        address channelInstance = _helperCreateChannelContract(ALICE, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        assertEq(
            fanToken.getClaimableAmount(channelInstance),
            0,
            "testClaimableAmountIsZeroWhenNoInflows: claimable amount should be zero"
        );
    }

    // @note TODO
    function testClaimableAmountWhenNoStakedBalanceUsesInflowRate(int96 flowRate) public {
        _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);
    }

    // @note TODO
    function testClaimableAmountWhenStakedBalanceExists() public { }

    //// getTotalClaimableAmount ////
    function testTotalClaimableAmountIsZeroWhenNoInflows() public {
        address channelA = _helperCreateChannelContract(ALICE, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        address channelB = _helperCreateChannelContract(BOB, FLOW_RATE, CREATOR_FEE_PERCENTAGE);

        address[] memory channels = new address[](2);

        channels[0] = channelA;
        channels[1] = channelB;
        (uint256 totalClaimableAmount, address[] memory claimableChannels) =
            fanToken.getTotalClaimableAmount(ALICE, channels);
        assertEq(
            totalClaimableAmount,
            0,
            "testTotalClaimableAmountIsZeroWhenNoInflows: total claimable amount should be zero"
        );
        assertEq(
            claimableChannels.length,
            channels.length,
            "testTotalClaimableAmountIsZeroWhenNoInflows: claimable channels should be length of channels passed"
        );
    }

    function testTotalClaimableAmountIsExpectedWithInflows() public {

        uint256 ADDITIONAL_TIME_TO_PASS = 1 days;
        uint256 TIME_SINCE_FAN_TOKEN_CREATED = block.timestamp - fanToken.startTime();
        uint256 REALTIME_MULTIPLIER = fanToken.multiplier();
        uint256 TOTAL_SUBSCRIPTION_INFLOW_RATE =  uint256(uint96(FLOW_RATE)*2);
        uint256 TOTAL_REWARDS = uint96(FLOW_RATE) * 2 * REALTIME_MULTIPLIER / ONE_HUNDRED_PERCENT;

        uint256 TOTAL_FLOW_BASED_REWARDS = TOTAL_REWARDS * fanToken.flowBasedRewardsPercentage() / ONE_HUNDRED_PERCENT;

        uint256 LOYALTY_BONUS_MULTIPLIER = fanToken.loyaltyBonusMultiplier();
        uint256 LOYALTY_BONUS_PERIOD = fanToken.loyaltyBonusPeriodUntilFull();


        address channelA = _helperCreateChannelContractAndSubscribeToIt(ALICE, CAROL, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        address channelB = _helperCreateChannelContractAndSubscribeToIt(BOB, CAROL, FLOW_RATE, CREATOR_FEE_PERCENTAGE);

        uint256 rewardFlowComponent = _getChannelFlowRewardsComponent(
            channelA,
            TOTAL_FLOW_BASED_REWARDS,
            FLOW_RATE*2
        );


        console.log("(t) TOTAL_REWARDS", TOTAL_REWARDS);
        console.log("(t) rewardFlowComponent", rewardFlowComponent);
        console.log("(t) TOTAL_FLOW_BASED_REWARDS", TOTAL_FLOW_BASED_REWARDS);

        uint256 rewards = rewardFlowComponent * 2;
        (uint256 lastUpdated,  ) = ChannelBase(channelA).getSubscriberFlowInfo(CAROL);
        vm.warp(block.timestamp + ADDITIONAL_TIME_TO_PASS);
        uint256 streamDuration = block.timestamp - lastUpdated;
        uint256 loyaltyBonus = 0;
        if(streamDuration < LOYALTY_BONUS_PERIOD) {
            rewards += (rewards * LOYALTY_BONUS_MULTIPLIER * streamDuration / LOYALTY_BONUS_PERIOD) / ONE_HUNDRED_PERCENT;
        } else {
            rewards += rewards * LOYALTY_BONUS_MULTIPLIER / ONE_HUNDRED_PERCENT;
        }

        address[] memory channels = new address[](2);
        channels[0] = channelA;
        channels[1] = channelB;
        (uint256 totalClaimableAmount, address[] memory claimableChannels) =
            fanToken.getTotalClaimableAmount(CAROL, channels);
        uint256 rounding = rewards - totalClaimableAmount;
        assertLt(
            rounding,
            2,
            "testTotalClaimableAmountIsExpectedWithInflows: rounding should be less than 2"
        );
        assertEq(
            claimableChannels.length,
            2,
            "testTotalClaimableAmountIsExpectedWithInflows: claimable channels should be full"
        );
        assertEq(
            totalClaimableAmount + rounding,
            rewards,
            "testTotalClaimableAmountIsExpectedWithInflows: total claimable amount should be full"
        );
    }
    // TODO: test that expected rewards for a channel is correct based on flow rate/staked amounts given the settings FanToken is deployed with

    // helpers function

    function _getChannelFlowRewardsComponent(
        address channel,
        uint256 totalFlowRateBasedRewards,
        int96 totalSubscriptionInflowRate
    ) internal view returns(uint256 flowBasedReward) {
        int96 totalInflowRate = ChannelBase(channel).totalInflowRate();
        if(totalInflowRate <= 0) return 0;
        uint256 propMinStreamCount = uint256(int256(totalInflowRate)) / 190258751902587; // 190258751902587 = we count based the min stream allowed in AF. (500/month)
        uint256  flowBasedRewardWeight = propMinStreamCount * ONE_HUNDRED_PERCENT / 1400;
        if(flowBasedRewardWeight >= FLOW_BASED_REWARD_BASE) return 0; // nothing to do
        uint256 channelFlowRateMultiplier = FLOW_BASED_REWARD_BASE - flowBasedRewardWeight;
        channelFlowRateMultiplier = channelFlowRateMultiplier > 20000 ? 20000 : channelFlowRateMultiplier; // max: 20K
        flowBasedReward = ((totalFlowRateBasedRewards * uint256(int256(totalInflowRate)) * channelFlowRateMultiplier)
            / uint256(int256(totalSubscriptionInflowRate))) / ONE_HUNDRED_PERCENT;
        return flowBasedReward;
    }

}
