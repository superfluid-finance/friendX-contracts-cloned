// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ChannelBase } from "../src/interfaces/ChannelBase.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { SFTest } from "./SFTest.t.sol";

contract FanTokenTest is SFTest {
    int96 internal constant FLOW_RATE = 385802469135802; // 1000 / month
    uint256 internal constant CREATOR_FEE_PERCENTAGE = 4269; // 1000 / month

    function setUp() public override {
        super.setUp();
        // deal some FAN to ALICE for testing
        deal(address(fanToken), ALICE, 1 ether);

        // start at a more realistic timestamp than 0 because of
        // the cooldown modifier logic
        vm.warp(block.timestamp + 60 days);
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

        _helperClaim(ALICE, channelInstance);

        _helperStake(ALICE, channelInstance, 100);

        _helperUnstake(ALICE, channelInstance, 100);

        vm.startPrank(ALICE);
        vm.expectRevert(IFanToken.FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER.selector);
        fanToken.stake(channelInstance, 100);
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

        _helperStake(ALICE, channelInstance, 100);
    }

    function testStakeToOwnChannel(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(ALICE, channelInstance, 100);
    }

    function testStakeToMultipleCreatorChannels(int96 flowRate) public {
        deal(address(fanToken), BOB, 1 ether);
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, CREATOR_FEE_PERCENTAGE);
        address carolChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(CAROL, BOB, flowRate, CREATOR_FEE_PERCENTAGE);

        _helperStake(BOB, aliceChannelAddress, 100);
        _helperStake(BOB, carolChannelAddress, 100);
    }

    function testStakeAgainAfterUnstakeCooldown(int96 flowRate) public {
        address channelInstance =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + 24 hours);

        _helperClaim(ALICE, channelInstance);

        _helperStake(ALICE, channelInstance, 100);

        _helperUnstake(ALICE, channelInstance, 100);

        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD() + 1);

        _helperStake(ALICE, channelInstance, 100);
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
        _helperStake(ALICE, aliceChannelAddress, 100);

        // stake some FAN to bob channel
        _helperStake(ALICE, bobChannelAddress, 100);

        // stake some FAN to alice
        _helperUnstake(ALICE, aliceChannelAddress, 50);

        // warp till unstake cooldown is over
        vm.warp(block.timestamp + fanToken.UNSTAKE_COOLDOWN_PERIOD() + 1);

        // unstake again
        _helperUnstake(ALICE, bobChannelAddress, 50);
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

        _helperStake(ALICE, channelInstance, 100);

        _helperUnstake(ALICE, channelInstance, 50);

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
        _helperStake(ALICE, aliceChannelAddress, 100);

        // unstake some FAN
        _helperUnstake(ALICE, aliceChannelAddress, 50);

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
        _helperStake(ALICE, aliceChannelAddress, 100);
        _helperStake(ALICE, bobChannelAddress, 100);

        _helperUnstake(ALICE, aliceChannelAddress, 50);

        address[] memory channelAddresses = new address[](2);
        channelAddresses[0] = aliceChannelAddress;
        channelAddresses[1] = bobChannelAddress;

        // claim all
        vm.startPrank(ALICE);
        fanToken.claimAll(channelAddresses);
        vm.stopPrank();
    }

    function testClaimAll(int96 flowRate) public {
        address aliceChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(ALICE, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        address bobChannelAddress =
            _helperCreateChannelContractAndSubscribeToIt(BOB, ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        // stake some FAN
        _helperStake(ALICE, aliceChannelAddress, 100);
        _helperStake(ALICE, bobChannelAddress, 100);

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
        _helperStake(ALICE, aliceChannelAddress, 100);
        _helperStake(ALICE, bobChannelAddress, 100);

        _helperUnstake(ALICE, aliceChannelAddress, 50);

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

    function testTotalRewardsDistributionIsZeroWhenNoInflows() public {
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
        (, int96 actualFlowRate,,) = _sf.cfa.getFlow(_subscriptionSuperToken, ALICE, aliceChannelAddress);

        assertEq(
            fanToken.getTotalRewardsDistribution(),
            uint256(uint96(actualFlowRate)),
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
        address channelA = _helperCreateChannelContractAndSubscribeToIt(ALICE, CAROL, FLOW_RATE, CREATOR_FEE_PERCENTAGE);
        address channelB = _helperCreateChannelContractAndSubscribeToIt(BOB, CAROL, FLOW_RATE, CREATOR_FEE_PERCENTAGE);

        vm.warp(block.timestamp + 24 hours);
        address[] memory channels = new address[](2);

        channels[0] = channelA;
        channels[1] = channelB;
        (uint256 totalClaimableAmount, address[] memory claimableChannels) =
            fanToken.getTotalClaimableAmount(CAROL, channels);

        assertEq(
            totalClaimableAmount,
            uint256(uint96(FLOW_RATE) * fanToken.flowBasedRewardsPercentage() / 10000 * 2),
            "testTotalClaimableAmountIsExpectedWithInflows: total claimable amount should be full"
        );
        assertEq(
            claimableChannels.length,
            2,
            "testTotalClaimableAmountIsExpectedWithInflows: claimable channels should be full"
        );
    }
    // TODO: test that expected rewards for a channel is correct based on flow rate/staked amounts given the settings FanToken is deployed with
}
