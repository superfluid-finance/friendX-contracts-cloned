// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SuperAppBase } from "superfluid-contracts/apps/SuperAppBase.sol";
import { ISuperfluid, ISuperfluidPool, ISuperToken } from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";

import { IFanToken } from "./IFanToken.sol";

abstract contract ChannelBase is Initializable, SuperAppBase {
    ///// EVENTS /////
    event Subscribed(address indexed subscriber, int96 flowRate);

    event SubscriptionUpdated(address indexed subscriber, int96 oldFlowRate, int96 newFlowRate);

    event Unsubscribed(address indexed subscriber, address indexed caller, int96 previousFlowRate);

    ///// CUSTOM ERRORS /////
    error NOT_SUPERFLUID_HOST();            // 0xd8ea032a
    error NOT_ACCEPTED_TOKEN();             // 0xb9c22c85
    error NOT_EMERGENCY();                  // 0x0b06cc31
    error NOT_ENOUGH_DEPOSIT();             // 0x5d997d88
    error INVALID_SUBSCRIPTION_FLOW_RATE(); // 0x8e10416e
    error ONLY_FAN_CAN_BE_CALLER();         // 0xe7f5e924
    error NO_UNITS_FOR_SUBSCRIBER();        // 0xfadc3ed0

    ///// CONSTANT VARIABLES /////
    bytes32 public constant CFAV1_TYPE = keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    /// @notice Returns the protocol fee (constant)
    /// @dev 5% = 500
    /// @return uint256 The protocol fee amount
    uint256 public constant PROTOCOL_FEE_AMOUNT = 500; // 5%

    /// @notice Returns the value representing one hundred percent in the system (constant)
    /// @dev 100% = 10000
    /// @return uint256
    uint256 public constant ONE_HUNDRED_PERCENT = 10_000; // 100%

    ///// IMMUTABLE VARIABLES /////
    /// @notice Returns the ISuperfluid interface
    /// @return ISuperfluid The Superfluid host interface
    ISuperfluid public immutable HOST;

    /// @notice Returns the address where protocol fees are sent
    /// @dev This is the address of the Superfluid Protocol
    /// @return address The address of the protocol fee destination
    address public immutable PROTOCOL_FEE_DESTINATION;

    /// @notice Returns the ISuperToken interface
    /// @return ISuperToken The SuperToken interface
    ISuperToken public immutable SUBSCRIPTION_SUPER_TOKEN;

    /// @notice Returns the IERC20 interface
    /// @return IERC20 The FAN token interface
    IFanToken public immutable FAN;

    ///// STATE VARIABLES /////
    /// @notice Returns the flow rate required for a subscription
    /// @return int96 The subscription flow rate
    int96 public subscriptionFlowRate;

    /// @notice Returns the contract owner's address (the creator)
    /// @return address The contract owner's address
    address public owner;

    /// @notice Returns the total inflow rate to the channel
    /// @return int96 The total inflow rate
    int96 public totalInflowRate;

    /// @notice Returns the ISuperfluidPool interface
    /// @return ISuperfluidPool The channel pool
    ISuperfluidPool public channelPool;

    /// @notice Returns the percentage fee for the creator
    /// @return uint256 The creator fee percentage
    uint256 public creatorFeePercentage;

    /// @notice Returns the liquidation period for the native asset
    /// @return uint256 The native asset liquidation period
    uint256 public nativeAssetLiquidationPeriod;

    /// @notice Returns the amount of deposits a user has
    /// @return deposit uint256 The total amount deposited by the user
    mapping(address user => uint256 deposit) public userDeposits;

    //// FUNCTIONS /////
    constructor(ISuperfluid host, address protocolFeeDest, ISuperToken subscriptionSuperToken, IFanToken _fan) {
        HOST = host;
        SUBSCRIPTION_SUPER_TOKEN = subscriptionSuperToken;
        FAN = _fan;
        PROTOCOL_FEE_DESTINATION = protocolFeeDest;
    }

    /// @notice Initializes the contract with given parameters
    /// @dev Sets the owner, flow rate, and creator fee percentage
    /// @param owner The address to be set as the owner of the contract
    /// @param flowRate The initial subscription flow rate to be set
    /// @param creatorFeePct The creator fee percentage
    /// @return channelPoolAddress The address of the SuperfluidPool for the channel
    function initialize(address owner, int96 flowRate, uint256 creatorFeePct)
        external
        virtual
        returns (address channelPoolAddress);

    /// @notice Handles the updating of units for the protocol, creator and subscriber when a subscriber stakes FAN tokens
    /// @dev We take the stakeDelta and split that into 3 parts:
    /// 1. protocolFeeUnitsDelta: the amount of units that will be allocated to the protocol fee destination
    /// 2. creatorUnitsDelta: the amount of units that will be allocated to the creator
    /// 3. subscriberUnitsDelta: the amount of units that will be allocated to the subscriber
    /// The user must be sending a stream to the Channel otherwise they are not considered a subscriber
    /// and therefore are not entitled to any cashbacks via staking.
    /// @param subscriber The address of the subscriber
    /// @param stakeDelta The additional amount of FAN tokens staked
    function handleStake(address subscriber, uint256 stakeDelta) external virtual;

    /// @notice Handles the updating of units for the protocol, creator and subscriber when a subscriber unstakes FAN tokens
    /// @dev We take the stakeDelta and split that into 3 parts:
    /// 1. protocolFeeUnitsDelta: the amount of units that will be allocated to the protocol fee destination
    /// 2. creatorUnitsDelta: the amount of units that will be allocated to the creator
    /// 3. subscriberUnitsDelta: the amount of units that will be allocated to the subscriber
    /// @param subscriber The address of the subscriber
    /// @param unstakeDelta The additional amount of FAN tokens staked
    function handleUnstake(address subscriber, uint256 unstakeDelta) external virtual;

    /// @notice Deposits the NativeAssetSuperToken into the Channel to be used as buffer
    /// @dev The user must have approved the Channel to transfer the amount of tokens
    /// @dev If the user does not have enough tokens, the transaction will revert in the create callback
    /// @param amount The amount of tokens to be deposited
    function depositBuffer(uint256 amount, bytes calldata ctx) external virtual returns (bytes memory newCtx);

    /// @notice Allows anyone to close streams for a given address in an emergency
    /// @dev An emergency is when the SuperApp is jailed
    /// @param subscriber The address of the subscriber
    function emergencyCloseStream(address subscriber) external virtual;

    /// @notice Allows anyone to close streams for a given list of addresses in an emergency
    /// @dev An emergency is when the SuperApp is jailed
    /// @param subscribers The addresses of the subscribers
    function emergencyCloseStreams(address[] calldata subscribers) external virtual;

    /// @notice Withdraws the NativeAssetSuperToken balance from the Channel
    /// @dev Only the owner can call this function IF the SuperApp is jailed
    function emergencyTransferTokens() external virtual;

    /// @notice Returns the subscriber flow rate and last updated timestamp
    /// @param subscriber The address of the subscriber
    /// @return lastUpdated uint256 The last updated timestamp
    /// @return flowRate int96 The subscriber flow rate
    function getSubscriberFlowInfo(address subscriber)
        external
        view
        virtual
        returns (uint256 lastUpdated, int96 flowRate);

    /// @notice Returns the subscriber cashback percentage
    /// @dev This is the percentage of the creator subscriptions that subscribers will receive as cashback
    /// @return uint256 The subscriber cashback percentage
    function getSubscriberCashbackPercentage() public view virtual returns (uint256);
}
