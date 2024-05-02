// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { stdError } from "forge-std/StdError.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SuperTokenV1Library } from "superfluid-contracts/apps/SuperTokenV1Library.sol";
import { ISETH } from "superfluid-contracts/interfaces/tokens/ISETH.sol";
import { ISuperfluid } from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperToken } from "superfluid-contracts/superfluid/SuperToken.sol";
import { ChannelBase } from "../src/interfaces/ChannelBase.sol";
import { AccountingHelperLibrary } from "../src/libs/AccountingHelperLibrary.sol";
import { SFTest } from "./SFTest.t.sol";

using SuperTokenV1Library for ISETH;
using SuperTokenV1Library for SuperToken;
using SafeCast for int256;
using SafeCast for uint256;

contract ChannelTest is SFTest {
    //// afterAgreementCreated ////

    function testRevertIfCallAfterAgreementCreatedDirectly(int96 flowRate, uint256 creatorFeePct) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, creatorFeePct);

        vm.expectRevert(ChannelBase.NOT_SUPERFLUID_HOST.selector);
        ChannelBase(channelInstance).afterAgreementCreated(
            _subscriptionSuperToken, address(_sf.cfa), keccak256(""), new bytes(0), new bytes(0), new bytes(0)
        );
    }

    function testRevertIfCreateFlowWithNotAcceptedSuperToken(int96 flowRate, uint256 creatorFeePct) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, creatorFeePct);

        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.NOT_ACCEPTED_TOKEN.selector);
        _ethX.createFlow(channelInstance, flowRate);
        vm.stopPrank();
    }

    function testRevertIfCreateFlowWithBadFlowRate(int96 subscriptionFlowRate, int96 flowRate, uint256 creatorFeePct)
        public
    {
        // @note we will likely set a minimum flow rate for subscriptions
        subscriptionFlowRate = int96(bound(subscriptionFlowRate, int96(0.01 ether) / int96(30 days), 1e15));
        vm.assume(subscriptionFlowRate != flowRate);
        flowRate = int96(bound(flowRate, 1, subscriptionFlowRate - 1));
        vm.assume(flowRate > 0);
        vm.assume(flowRate < subscriptionFlowRate);
        address channelInstance = _helperCreateChannelContract(ALICE, subscriptionFlowRate, creatorFeePct);

        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
        _subscriptionSuperToken.createFlow(channelInstance, flowRate);
        vm.stopPrank();
    }

    function testStartStreamToChannel(int96 flowRate, uint256 creatorFeePct) public {
        _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
    }

    //// afterAgreementUpdated ////
    function testRevertIfUpdateStreamBelowSubscriptionToChannel(uint256 creatorFeePct) public {
        int96 flowRate = int96(0.01 ether) / int96(30 days);
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
        _subscriptionSuperToken.updateFlow(channelInstance, flowRate - 1);
        vm.stopPrank();
    }

    function testIncreaseSubscriptionFlowRateToChannel(int96 flowRate, uint256 creatorFeePct) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        int96 senderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        _helperUpdateSubscriptionFlowRate(BOB, channelInstance, senderToAppFlowRate + 42069);
        int96 newSenderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        assertEq(
            senderToAppFlowRate + 42069,
            newSenderToAppFlowRate,
            "testIncreaseSubscriptionFlowRateToChannel: flow rate not set correctly"
        );

        _assertAppNotJailed(channelInstance);
    }

    function testDecreaseSubscriptionFlowRateToChannel(int96 flowRate, uint256 creatorFeePct) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        int96 senderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        _helperUpdateSubscriptionFlowRate(BOB, channelInstance, senderToAppFlowRate - 42069);
        int96 newSenderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        assertEq(
            senderToAppFlowRate - 42069,
            newSenderToAppFlowRate,
            "testDecreaseSubscriptionFlowRateToChannel: flow rate not set correctly"
        );
        _assertAppNotJailed(channelInstance);
    }

    //// afterAgreementTerminated ////

    function testRevertIfCallAfterAgreementTerminatedDirectly(int96 flowRate, uint256 creatorFeePct) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, creatorFeePct);

        vm.expectRevert(ChannelBase.NOT_SUPERFLUID_HOST.selector);
        bytes memory newCtx = ChannelBase(channelInstance).afterAgreementTerminated(
            _subscriptionSuperToken, address(_sf.cfa), keccak256(""), new bytes(0), new bytes(0), new bytes(0)
        );
        assertEq(newCtx, new bytes(0), "testRevertIfCallAfterAgreementTerminatedDirectly: newCtx not empty");
    }

    function testRevertButNoJailIfDeleteNonExistentFlow() public { }

    function testUnsubscribeFromChannel(int96 flowRate, uint256 creatorFeePct) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        vm.startPrank(BOB);
        _subscriptionSuperToken.deleteFlow(BOB, channelInstance);
        vm.stopPrank();

        int96 senderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        assertEq(senderToAppFlowRate, 0, "testCloseStreamToSuperApp: flow rate not set correctly");

        _assertAppNotJailed(channelInstance);
    }

    //// handleStake ////

    function testRevertIfHandleStakeCallerIsNotFanToken(int96 flowRate, uint256 creatorFeePct) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.ONLY_FAN_CAN_BE_CALLER.selector);
        ChannelBase(channelInstance).handleStake(BOB, 69420);
        vm.stopPrank();
    }

    // function testRevertIfHandleStakeWithNoFlow(int96 flowRate, uint256 creatorFeePct) public {
    //     address channelInstance = _helperCreateChannelContract(ALICE, flowRate, creatorFeePct);
    //     vm.startPrank(address(fanToken));
    //     vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
    //     ChannelBase(channelInstance).handleStake(ALICE, 42069);
    //     vm.stopPrank();
    // }

    function testHandleStake(uint128 stakeDelta, int96 flowRate, uint256 creatorFeePct) public {
        stakeDelta = bound(stakeDelta, 0.1 ether, 1_000 ether).toUint128();

        // we must create a channel contract and stream to it before staking
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        ChannelBase channel = ChannelBase(channelInstance);
        _helperHandleStake(channel, BOB, stakeDelta);
    }

    //// handleUnstake ////

    function testRevertIfHandleUnstakeCallerIsNotFanToken(int96 flowRate, uint256 creatorFeePct) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.ONLY_FAN_CAN_BE_CALLER.selector);
        ChannelBase(channelInstance).handleUnstake(BOB, 69420);
        vm.stopPrank();
    }

    function testHandleUnstake(uint128 stakeDelta, uint128 unstakeDelta, int96 flowRate, uint256 creatorFeePct)
        public
    {
        stakeDelta = bound(stakeDelta, 0.001 ether, 1_000 ether).toUint128();
        uint128 unstakeDeltaMax = stakeDelta;
        unstakeDelta = bound(unstakeDelta, 0.001 ether, unstakeDeltaMax).toUint128();

        // we must create a channel contract and stream to it before staking
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, creatorFeePct);
        ChannelBase channel = ChannelBase(channelInstance);
        _helperHandleStake(channel, BOB, stakeDelta);

        _helperHandleUnstake(channel, BOB, unstakeDelta);
    }
}
