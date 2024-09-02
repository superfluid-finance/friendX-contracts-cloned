// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { stdError } from "forge-std/StdError.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISETH } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/tokens/ISETH.sol";
import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

import { MANDATORY_CREATOR_FEE_PCT } from "../src/ChannelFactory.sol";
import { IFanToken, Channel, ChannelBase } from "../src/Channel.sol";
import { AccountingHelperLibrary } from "../src/libs/AccountingHelperLibrary.sol";
import { SFTest } from "./SFTest.t.sol";

using SuperTokenV1Library for ISETH;
using SuperTokenV1Library for SuperToken;
using SafeCast for int256;
using SafeCast for uint256;

contract ChannelLayoutTest is Channel {
    constructor() Channel(ISuperfluid(address(0)),
                          SuperToken(address(0)), IFanToken(address(0)),
                          address(0), 0,
                          0, 0) { }
    function testStorageLayout() external pure {
        uint256 slot;
        uint256 offset;

        //   0 ..   0  | Initializable      | uint8 _initialized; bool _initialized;

        // Channel storages

        assembly { slot:= subscriptionFlowRate.slot offset := subscriptionFlowRate.offset }
        require(slot == 0 && offset == 2, "subscriptionFlowRate changed location");

        assembly { slot:= owner.slot offset := owner.offset }
        require(slot == 1 && offset == 0, "owner changed location");

        assembly { slot:= totalInflowRate.slot offset := totalInflowRate.offset }
        require(slot == 1 && offset == 20, "totalInflowRate changed location");

        assembly { slot:= channelPool.slot offset := channelPool.offset }
        require(slot == 2 && offset == 0, "channelPool changed location");

        assembly { slot:= creatorFeePercentage.slot offset := creatorFeePercentage.offset }
        require(slot == 3 && offset == 0, "creatorFeePercentage changed location");

        assembly { slot:= nativeAssetLiquidationPeriod.slot offset := nativeAssetLiquidationPeriod.offset }
        require(slot == 4 && offset == 0, "nativeAssetLiquidationPeriod changed location");

        assembly { slot:= userDeposits.slot offset := userDeposits.offset }
        require(slot == 5 && offset == 0, "userDeposits changed location");

        assembly { slot:= currentRegimeRevision.slot offset := userDeposits.offset }
        require(slot == 6 && offset == 0, "currentRegimeRevision changed location");

        assembly { slot:= stakerRegimeRevisions.slot offset := userDeposits.offset }
        require(slot == 7 && offset == 0, "stakerRegimeRevisions changed location");
    }
}

contract ChannelTest is SFTest {
    uint256 internal constant CREATOR_FEE_PERCENTAGE = MANDATORY_CREATOR_FEE_PCT;

    //// afterAgreementCreated ////

    function testRevertIfCallAfterAgreementCreatedDirectly(int96 flowRate) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.expectRevert(ChannelBase.NOT_SUPERFLUID_HOST.selector);
        ChannelBase(channelInstance).afterAgreementCreated(
            _subscriptionSuperToken, address(_sf.cfa), keccak256(""), new bytes(0), new bytes(0), new bytes(0)
        );
    }

    function testRevertIfCreateFlowWithNotAcceptedSuperToken(int96 flowRate) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.NOT_ACCEPTED_TOKEN.selector);
        _ethX.createFlow(channelInstance, flowRate);
        vm.stopPrank();
    }

    function testRevertIfCreateFlowWithBadFlowRate(int96 subscriptionFlowRate, int96 flowRate)
        public
    {
        // @note we will likely set a minimum flow rate for subscriptions
        subscriptionFlowRate = int96(bound(subscriptionFlowRate, int96(0.01 ether) / int96(30 days), 1e15));
        vm.assume(subscriptionFlowRate != flowRate);
        flowRate = int96(bound(flowRate, 1, subscriptionFlowRate - 1));
        vm.assume(flowRate > 0);
        vm.assume(flowRate < subscriptionFlowRate);
        address channelInstance = _helperCreateChannelContract(ALICE, subscriptionFlowRate, CREATOR_FEE_PERCENTAGE);

        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
        _subscriptionSuperToken.createFlow(channelInstance, flowRate);
        vm.stopPrank();
    }

    function testStartStreamToChannel(int96 flowRate) public {
        _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate, CREATOR_FEE_PERCENTAGE);
    }

    //// afterAgreementUpdated ////
    function testRevertIfUpdateStreamBelowSubscriptionToChannel() public {
        int96 flowRate = int96(0.01 ether) / int96(30 days);
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector);
        _subscriptionSuperToken.updateFlow(channelInstance, flowRate - 1);
        vm.stopPrank();
    }

    function testIncreaseSubscriptionFlowRateToChannel(int96 flowRate) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
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

    function testDecreaseSubscriptionFlowRateToChannel(int96 flowRate) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
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

    function testRevertIfCallAfterAgreementTerminatedDirectly(int96 flowRate) public {
        vm.assume(flowRate < 1e9);
        address channelInstance = _helperCreateChannelContract(ALICE, flowRate, CREATOR_FEE_PERCENTAGE);

        vm.expectRevert(ChannelBase.NOT_SUPERFLUID_HOST.selector);
        bytes memory newCtx = ChannelBase(channelInstance).afterAgreementTerminated(
            _subscriptionSuperToken, address(_sf.cfa), keccak256(""), new bytes(0), new bytes(0), new bytes(0)
        );
        assertEq(newCtx, new bytes(0), "testRevertIfCallAfterAgreementTerminatedDirectly: newCtx not empty");
    }

    function testRevertButNoJailIfDeleteNonExistentFlow() public { }

    function testUnsubscribeFromChannel(int96 flowRate) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        vm.startPrank(BOB);
        _subscriptionSuperToken.deleteFlow(BOB, channelInstance);
        vm.stopPrank();

        int96 senderToAppFlowRate = _subscriptionSuperToken.getFlowRate(BOB, channelInstance);
        assertEq(senderToAppFlowRate, 0, "testCloseStreamToSuperApp: flow rate not set correctly");

        _assertAppNotJailed(channelInstance);
    }

    //// handleStake ////

    function testRevertIfHandleStakeCallerIsNotFanToken(int96 flowRate) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.ONLY_FAN_CAN_BE_CALLER.selector);
        ChannelBase(channelInstance).handleStake(BOB, 69420);
        vm.stopPrank();
    }

    // FIXME why does this fail
    /* function testRevertIfHandleStakeWithNoFlow(int96 flowRate) public { */
    /*     address channelInstance = _helperCreateChannelContract(ALICE, flowRate, CREATOR_FEE_PERCENTAGE); */
    /*     vm.startPrank(address(fanToken)); */
    /*     vm.expectRevert(ChannelBase.INVALID_SUBSCRIPTION_FLOW_RATE.selector); */
    /*     ChannelBase(channelInstance).handleStake(ALICE, 42069); */
    /*     vm.stopPrank(); */
    /* } */

    function testHandleStake(uint128 stakeDelta, int96 flowRate) public {
        stakeDelta = bound(stakeDelta, 0.1 ether, 1_000 ether).toUint128();

        // we must create a channel contract and stream to it before staking
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        ChannelBase channel = ChannelBase(channelInstance);
        _helperHandleStake(channel, BOB, stakeDelta);
    }

    //// handleUnstake ////

    function testRevertIfHandleUnstakeCallerIsNotFanToken(int96 flowRate) public {
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        vm.startPrank(BOB);
        vm.expectRevert(ChannelBase.ONLY_FAN_CAN_BE_CALLER.selector);
        ChannelBase(channelInstance).handleUnstake(BOB, 69420);
        vm.stopPrank();
    }

    function testHandleUnstake(uint128 stakeDelta, uint128 unstakeDelta, int96 flowRate)
        public
    {
        stakeDelta = bound(stakeDelta, 0.001 ether, 1_000 ether).toUint128();
        uint128 unstakeDeltaMax = stakeDelta;
        unstakeDelta = bound(unstakeDelta, 0.001 ether, unstakeDeltaMax).toUint128();

        // we must create a channel contract and stream to it before staking
        address channelInstance = _helperCreateChannelContractAndSubscribeToIt(ALICE, BOB, flowRate,
                                                                               CREATOR_FEE_PERCENTAGE);
        ChannelBase channel = ChannelBase(channelInstance);
        _helperHandleStake(channel, BOB, stakeDelta);

        _helperHandleUnstake(channel, BOB, unstakeDelta);
    }
}
