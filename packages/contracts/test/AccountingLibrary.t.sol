// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import { Channel, ISuperfluid } from "../src/Channel.sol";
import { AccountingHelperLibrary, ONE_HUNDRED_PERCENT } from "../src/libs/AccountingHelperLibrary.sol";

contract AccountingHelperLibraryTest is Test {
    // @note These constants are hardcoded, they reflect what is in ChannelBase.sol

    uint256 public constant PROTOCOL_FEE_AMOUNT = 500; // 5%

    function testAccountLibrarySplit(uint256 scalingFactor,
                                     uint256 stakeDelta, uint256 creatorFeeAmount) public pure {
        vm.assume(scalingFactor > 0);
        vm.assume(creatorFeeAmount < ONE_HUNDRED_PERCENT - PROTOCOL_FEE_AMOUNT);

        // limit it to the max of what units are stored in Semantic Money
        // 1_000 ether with 10 decimals is around 100 billion FAN being staked at once
        stakeDelta = bound(stakeDelta, 0, 1_000 ether);

        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta) =
            AccountingHelperLibrary.getPoolUnitDeltaAmounts(scalingFactor,
                                                            stakeDelta, PROTOCOL_FEE_AMOUNT, creatorFeeAmount);

        uint256 unitsSum = stakeDelta / scalingFactor;
        assertEq(
            protocolFeeUnitsDelta + creatorUnitsDelta + subscriberUnitsDelta,
            unitsSum,
            "testAccountLibrarySplit: Sum of unit deltas is equal to stake delta"
        );
    }
}
