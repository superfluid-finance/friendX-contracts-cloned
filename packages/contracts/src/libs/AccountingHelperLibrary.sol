// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

using SafeCast for uint256;


uint256 constant ONE_HUNDRED_PERCENT = 100_00;

library AccountingHelperLibrary {
    /// @dev Returns the pool units delta amounts for protocol, creator, and subscriber
    /// @param stakeDelta The amount of FAN tokens to stake
    /// @param protocolFeeAmount The amount of the protocol fee in the pool units
    /// @param creatorFeePercentage The percentage of the creator fee in the pool units
    /// @return protocolFeeUnitsDelta The amount pool units delta to allocate/deallocate to/from the protocol
    /// @return creatorUnitsDelta The amount pool units delta to allocate/deallocate to/from the creator
    /// @return subscriberUnitsDelta The amount pool units delta to allocate/deallocate to/from the subscriber
    function getPoolUnitDeltaAmounts (uint256 scalingFactor,
                                      uint256 stakeDelta,
                                      uint256 protocolFeeAmount,
                                      uint256 creatorFeePercentage) internal pure
        returns (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta)
    {
        // let's say we expect the maximum total amount of flow rate to be $1 billion/yr
        // $31.709791983764585/s => 0.015854895991882292 ETH/s => 15854895991882292 * 1e8 (SCALING)
        // the scaling ensures that we don't lose precision when it comes to the percentages as users
        // unstake or something

        stakeDelta = stakeDelta / scalingFactor;
        // @note we do not square the stake delta amount
        // stakeDelta = stakeDelta * stakeDelta;

        protocolFeeUnitsDelta = (stakeDelta * protocolFeeAmount / ONE_HUNDRED_PERCENT).toUint128();
        creatorUnitsDelta = (stakeDelta * creatorFeePercentage / ONE_HUNDRED_PERCENT).toUint128();
        subscriberUnitsDelta = (stakeDelta - protocolFeeUnitsDelta - creatorUnitsDelta).toUint128();
    }
}
