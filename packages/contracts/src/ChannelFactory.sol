// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {
    ISuperApp,
    ISuperfluid,
    ISuperToken,
    SuperAppDefinitions
} from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { Channel } from "./Channel.sol";
import { IChannelFactory } from "./interfaces/IChannelFactory.sol";
import { ChannelBase } from "./interfaces/ChannelBase.sol";

// TODO Make ChannelFactory an upgradeable proxy contract itself

/// @title Channel Factory Contract
/// @author Superfluid
/// @notice Deploys new Channel contracts
/// @dev Utilizes create2 to deploy new contracts and enables deterministic address computation
contract ChannelFactory is IChannelFactory {
    ISuperfluid public immutable HOST;
    UpgradeableBeacon public immutable CHANNEL_BEACON;

    mapping(address channel => bool isCreated) internal _channels;

    constructor(ISuperfluid host, address implementation) {
        HOST = host;

        // Deploy the beacon with the implementation contract
        CHANNEL_BEACON = new UpgradeableBeacon(implementation);

        // Transfer ownership of the beacon to the deployer
        CHANNEL_BEACON.transferOwnership(msg.sender);
    }

    function isChannelCreated(address channel) external view override returns (bool isCreated) {
        return _channels[channel];
    }

    /// @inheritdoc IChannelFactory
    function createChannelContract(int96 subscriptionFlowRate, uint256 creatorFeePct)
        external
        override
        returns (address instance)
    {
        instance = createChannelContract(msg.sender, subscriptionFlowRate, creatorFeePct);
    }

    /// @inheritdoc IChannelFactory
    function createChannelContract(address channelOwner, int96 subscriptionFlowRate, uint256 creatorFeePct)
        public
        override
        returns (address instance)
    {
        if (subscriptionFlowRate < 0) revert FLOW_RATE_NEGATIVE();

        ChannelBase channel = ChannelBase(getBeaconImplementation());
        // @note Creator fee is 25%
        // @note Protocol fee is 5%
        // @note Cashback is 70%
        if (creatorFeePct != channel.ONE_HUNDRED_PERCENT() / 4) {
            revert INVALID_CREATOR_FEE_PCT();
        }

        // Use create2 to deploy a BeaconProxy with the hashed encoded channelOwner as the salt
        instance = address(new BeaconProxy{ salt: keccak256(abi.encode(channelOwner)) }(address(CHANNEL_BEACON), ""));

        _channels[instance] = true;

        // initialize the owner of the Channel instance and the subscription flow rate
        address poolAddress = ChannelBase(instance).initialize(channelOwner, subscriptionFlowRate, creatorFeePct);

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL | SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP;
        HOST.registerApp(ISuperApp(instance), configWord);

        emit ChannelContractCreated(
            msg.sender, channelOwner, instance, poolAddress, creatorFeePct, subscriptionFlowRate
        );
    }

    /// @inheritdoc IChannelFactory
    function getChannelAddress(address user) external view override returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            keccak256(abi.encode(user)),
                            keccak256(
                                abi.encodePacked(
                                    type(BeaconProxy).creationCode, abi.encode(address(CHANNEL_BEACON), "")
                                )
                            )
                        )
                    )
                )
            )
        );
    }

    /// @inheritdoc IChannelFactory
    function getBeaconImplementation() public view returns (address) {
        return CHANNEL_BEACON.implementation();
    }
}
