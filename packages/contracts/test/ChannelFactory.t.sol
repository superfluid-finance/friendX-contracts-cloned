// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { ONE_HUNDRED_PERCENT } from "../src/libs/AccountingHelperLibrary.sol";
import { ChannelFactory, IChannelFactory, MANDATORY_CREATOR_FEE_PCT } from "../src/ChannelFactory.sol";
import { Channel } from "../src/ChannelFactory.sol";

import { SFTest } from "./SFTest.t.sol";


/// TODO: find + use the foundry upgrader tool for testing, but also for scripts
/// do this with all contracts that are upgradeable
/// TODO: ensure we are following the rareskills styling convention

contract ChannelFactoryTest is SFTest {
    //// constructor ////

    function testBeaconImplementationIsCorrectlySet() public view {
        assertEq(
            address(channelLogic),
            channelFactory.getBeaconImplementation(),
            "testBeaconImplementationIsCorrectlySet: beacon logic incorrectly set"
        );
    }

    function testBeaconIsCorrectlyDeployed() public view {
        assertFalse(
            address(channelFactory.CHANNEL_BEACON()) == address(0),
            "testBeaconIsCorrectlyDeployed: beacon incorrectly deployed"
        );
        assertEq(
            channelFactory.CHANNEL_BEACON().owner(),
            ADMIN,
            "testBeaconIsCorrectlyDeployed: beacon owner incorrectly set"
        );
    }

    //// createChannelContract ////

    function testRevertIfDeployChannelContractHasNegativeFlowRate(int96 flowRate) public {
        vm.assume(flowRate < 0);
        vm.expectRevert(IChannelFactory.FLOW_RATE_NEGATIVE.selector);
        channelFactory.createChannelContract(flowRate, MANDATORY_CREATOR_FEE_PCT);
    }

    function testRevertIfDeployChannelContractHasInvalidCreatorFeePct(int96 flowRate, uint256 creatorFeePct) public {
        vm.assume(flowRate > 0);
        creatorFeePct = bound(creatorFeePct,
                              ONE_HUNDRED_PERCENT - channelLogic.PROTOCOL_FEE_AMOUNT() + 1,
                              type(uint256).max);

        vm.expectRevert(IChannelFactory.INVALID_CREATOR_FEE_PCT.selector);
        channelFactory.createChannelContract(flowRate, creatorFeePct);
    }

    function testRevertIfDeployChannelContractAlreadyDeployed(int96 flowRate, int96 secondFlowRate) public {
        vm.assume(flowRate > 0);

        channelFactory.createChannelContract(flowRate, MANDATORY_CREATOR_FEE_PCT);

        // The flow rate should not impact whether this reverts or not.
        // If the flow rate is the same/different.
        vm.expectRevert();
        channelFactory.createChannelContract(secondFlowRate, MANDATORY_CREATOR_FEE_PCT);
    }

    function testRevertIfOnBehalfDeployChannelIsAlreadyDeployed(int96 flowRate) public {
        vm.assume(flowRate > 0);

        channelFactory.createChannelContract(address(this), flowRate, MANDATORY_CREATOR_FEE_PCT);

        // The flow rate should not impact whether this reverts or not.
        // If the flow rate is the same/different.
        vm.expectRevert();
        channelFactory.createChannelContract(address(this), flowRate, MANDATORY_CREATOR_FEE_PCT);
    }

    function testDeployChannelContract(int96 flowRate) public {
        _helperCreateChannelContract(ALICE, flowRate, MANDATORY_CREATOR_FEE_PCT);
    }

    function testDeployChannelContractOnBehalf(int96 flowRate) public {
        _helperCreateChannelContractOnBehalf(address(this), ALICE, flowRate, MANDATORY_CREATOR_FEE_PCT);
    }

    //// upgradeTo ////

    function testRevertIfUpgradeBeaconByNotOwner() public {
        // ADMIN is the owner
        address notOwner = ALICE;

        UpgradeableBeacon beacon = channelFactory.CHANNEL_BEACON();

        vm.startPrank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        beacon.upgradeTo(address(0x0));
        vm.stopPrank();
    }

    function testRevertIfUpgradeBeaconToNotContract() public {
        UpgradeableBeacon beacon = channelFactory.CHANNEL_BEACON();

        vm.startPrank(ADMIN);
        vm.expectRevert("UpgradeableBeacon: implementation is not a contract");
        beacon.upgradeTo(address(0x0));
        vm.stopPrank();
    }
}
