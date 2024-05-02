// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IChannelFactory {
    ///// EVENTS /////
    /// @dev emitted when a new channel contract is created
    /// @param transactionExecutor the address of the transaction executor
    /// @param owner the owner of the channel contract
    /// @param channelContract the address of the newly created channel contract
    /// @param ethXPoolAddress the address of the newly created ETHx pool for the channel
    /// @param creatorFeePct the creator fee percentage
    /// @param initialSubscriptionFlowRate the initial subscription flow rate
    event ChannelContractCreated(
        address indexed transactionExecutor,
        address indexed owner,
        address indexed channelContract,
        address ethXPoolAddress,
        uint256 creatorFeePct,
        int96 initialSubscriptionFlowRate
    );

    ///// CUSTOM ERRORS /////
    error FLOW_RATE_NEGATIVE();         // 0x6093635e
    error INVALID_CREATOR_FEE_PCT();    // 0xee6f0ba8

    ///// WRITE FUNCTIONS /////

    /// @notice Creates a new channel contract with specified flow rate and creator fee percentage
    /// @dev This function uses CREATE2 to deploy a new beacon proxy contract and initializes with the given parameters
    /// @param channelOwner The admin of the channel
    /// @param flowRate The subscriptionflow rate for the channel
    /// @param creatorFeePct The creator fee percentage for the channel
    /// @return instance The address of the newly created channel beacon proxy contract
    function createChannelContract(address channelOwner, int96 flowRate, uint256 creatorFeePct)
        external
        returns (address instance);

    /// @notice Creates a new channel contract with specified flow rate and creator fee percentage
    /// @dev This function uses CREATE2 to deploy a new beacon proxy contract and initializes with the given parameters
    /// @param flowRate The subscriptionflow rate for the channel
    /// @param creatorFeePct The creator fee percentage for the channel
    /// @return instance The address of the newly created channel beacon proxy contract
    function createChannelContract(int96 flowRate, uint256 creatorFeePct) external returns (address instance);

    /// @notice Computes and returns the address of a channel for a given user
    /// @dev Precomputes the channel address based on the user's address as a salt
    /// @param user The address of the user for whom the channel address is computed
    /// @return channel The computed address of the user's channel
    function getChannelAddress(address user) external view returns (address channel);

    ///// VIEW FUNCTIONS /////
    /// @notice Returns whether the `channel` exists
    /// @dev Returns whether the address is a "canonical" channel created via the factory
    /// @param channel The address of the creator channel to check
    /// @return isCreated true if the channel is created, false otherwise
    function isChannelCreated(address channel) external view returns (bool isCreated);

    /// @notice Returns the address of the beacon implementation
    /// @dev The beacon implementation is the Channel logic contract
    /// @return beaconImplementation The address of the beacon implementation contract
    function getBeaconImplementation() external view returns (address beaconImplementation);

    /// @notice Returns the beacon address
    /// @dev The beacon which all Channel beacon proxies are pointing to
    /// @return channelBeacon The UpgradeableBeacon instance
    function CHANNEL_BEACON() external view returns (UpgradeableBeacon channelBeacon);
}
