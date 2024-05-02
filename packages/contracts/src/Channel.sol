// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IConstantFlowAgreementV1,
    IGeneralDistributionAgreementV1,
    ISuperApp,
    ISuperfluid,
    ISuperfluidPool,
    ISuperToken
} from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperfluidGovernanceBase } from "superfluid-contracts/gov/SuperfluidGovernanceBase.sol";
import { PoolConfig } from "superfluid-contracts/interfaces/agreements/gdav1/IGeneralDistributionAgreementV1.sol";
import { SuperTokenV1Library } from "superfluid-contracts/apps/SuperTokenV1Library.sol";

import { ChannelBase } from "./interfaces/ChannelBase.sol";
import { IFanToken } from "./interfaces/IFanToken.sol";
import { AccountingHelperLibrary } from "./libs/AccountingHelperLibrary.sol";

using SafeCast for uint256;
using SuperTokenV1Library for ISuperToken;

/// @title Channel
/// @author Superfluid
/// @notice This contract represents a channel that can be subscribed to by fans
/// @dev This contract is a SuperApp that reacts to CFAv1 flows
contract Channel is ChannelBase {
    //// MODIFIERS ////
    modifier onlyFans() {
        if (msg.sender != address(FAN)) revert ONLY_FAN_CAN_BE_CALLER();
        _;
    }

    //// FUNCTIONS ////
    constructor(ISuperfluid host, address protocolFeeDest, ISuperToken ethX, IFanToken _fan)
        ChannelBase(host, protocolFeeDest, ethX, _fan)
    {
        _disableInitializers();
    }

    function initialize(address _owner, int96 _flowRate, uint256 creatorFeePct)
        external
        override
        initializer
        returns (address channelPoolAddress)
    {
        // set the owner of the contract
        owner = _owner;

        // set the subscription flow rate
        subscriptionFlowRate = _flowRate;

        // @note If we change the liquidation period, we must also upgrade this contract
        SuperfluidGovernanceBase gov = SuperfluidGovernanceBase(address(HOST.getGovernance()));
        (uint256 liquidationPeriod,) = gov.getPPPConfig(HOST, SUBSCRIPTION_SUPER_TOKEN);
        nativeAssetLiquidationPeriod = liquidationPeriod;

        // define the poolconfig and create a pool
        PoolConfig memory poolConfig =
            PoolConfig({ transferabilityForUnitsOwner: false, distributionFromAnyAddress: true });
        channelPool = SUBSCRIPTION_SUPER_TOKEN.createPool(address(this), poolConfig);
        channelPoolAddress = address(channelPool);

        // grant the channel owner a single unit so they receive 100% of the income
        // prior to any stakers
        channelPool.updateMemberUnits(_owner, 1);

        // set the creator fee percentage
        creatorFeePercentage = creatorFeePct;
    }

    /// @inheritdoc ChannelBase
    function handleStake(address subscriber, uint256 stakeDelta) external override onlyFans {
        // @note if there are no units in the channel pool, we send first transfer the accumulated streamed
        // tokens to the channel owner
        if (channelPool.getTotalUnits() == 0) {
            SUBSCRIPTION_SUPER_TOKEN.transfer(owner, SUBSCRIPTION_SUPER_TOKEN.balanceOf(address(this)));
        }

        // Get the amount of units that will be allocated to the protocol fee destination, creator and subscriber
        // based on the stakeDelta
        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta) =
        AccountingHelperLibrary.getPoolUnitDeltaAmounts(
            stakeDelta, ONE_HUNDRED_PERCENT, PROTOCOL_FEE_AMOUNT, creatorFeePercentage
        );

        uint256 cashbackPercentage = getSubscriberCashbackPercentage();

        if (subscriberUnitsDelta == 0 && cashbackPercentage > 0) revert NO_UNITS_FOR_SUBSCRIBER();

        (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentSubscriberUnits) =
            _getCurrentPoolUnits(subscriber);

        // rebalance the protocol fee units and the creator units so that they are in the correct proportions
        channelPool.updateMemberUnits(PROTOCOL_FEE_DESTINATION, currentProtocolPoolUnits + protocolFeeUnitsDelta);

        // handle the case where the owner is subscribing to their own channel
        if (subscriber == owner) {
            // give the owner-subscriber the creator units and the subscriber units
            channelPool.updateMemberUnits(
                subscriber, currentCreatorPoolUnits + creatorUnitsDelta + subscriberUnitsDelta
            );
        } else {
            // the subscriber is not the owner, so we need to update their units separately
            channelPool.updateMemberUnits(owner, currentCreatorPoolUnits + creatorUnitsDelta);
            // if the cashback percentage is 0, there is nothing to update for the subscriber
            if (cashbackPercentage > 0) {
                channelPool.updateMemberUnits(subscriber, currentSubscriberUnits + subscriberUnitsDelta);
            }
        }

        // start/update GDA flow distribution to the protocol, owner and subscribers
        // we only start the flow if the total inflow rate is greater than 0
        // @note this will revert if the contract does not have enough tokens for buffer
        // to start the flow
        if (totalInflowRate > 0) {
            SUBSCRIPTION_SUPER_TOKEN.distributeFlow(address(this), channelPool, totalInflowRate);
        }
    }

    /// @inheritdoc ChannelBase
    function handleUnstake(address subscriber, uint256 unstakeDelta) external override onlyFans {
        (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentSubscriberUnits) =
            _getCurrentPoolUnits(subscriber);

        uint256 cashbackPercentage = getSubscriberCashbackPercentage();

        // if the subscriber has no units, they have deleted their flow, so unstaking should not impact
        // the unit amounts for the different accounts as this has been handled in the onFlowDeleted callback
        if (currentSubscriberUnits == 0 && cashbackPercentage > 0) return;

        // Get the amount of units that will be unallocated from the protocol fee destination, creator and subscriber
        // based on the unstakeDelta
        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta) =
        AccountingHelperLibrary.getPoolUnitDeltaAmounts(
            unstakeDelta, ONE_HUNDRED_PERCENT, PROTOCOL_FEE_AMOUNT, creatorFeePercentage
        );

        // rebalance the protocol fee units and the creator units so that they are in the correct proportions
        channelPool.updateMemberUnits(PROTOCOL_FEE_DESTINATION, currentProtocolPoolUnits - protocolFeeUnitsDelta);

        // handle the case where the owner is unsubscribing from their own channel
        if (subscriber == owner) {
            // remove the creator units and subscriber units from the owner-subscriber
            channelPool.updateMemberUnits(
                subscriber, currentCreatorPoolUnits - creatorUnitsDelta - subscriberUnitsDelta
            );
        } else {
            // the subscriber is not the owner, so we need to update their units separately
            channelPool.updateMemberUnits(owner, currentCreatorPoolUnits - creatorUnitsDelta);
            // if the cashback percentage is 0, there is nothing to update for the subscriber
            if (cashbackPercentage > 0) {
                channelPool.updateMemberUnits(subscriber, currentSubscriberUnits - subscriberUnitsDelta);
            }
        }
    }

    /// @inheritdoc ChannelBase
    function depositBuffer(uint256 amount, bytes calldata ctx) external override returns (bytes memory newCtx) {
        if (amount > 0) {
            ISuperfluid.Context memory context = HOST.decodeCtx(ctx);
            SUBSCRIPTION_SUPER_TOKEN.transferFrom(context.msgSender, address(this), amount);
            userDeposits[context.msgSender] += amount;
        }
        return ctx;
    }

    /// @inheritdoc ChannelBase
    function emergencyCloseStream(address subscriber) external override {
        if (!HOST.isAppJailed(ISuperApp(address(this)))) revert NOT_EMERGENCY();

        SUBSCRIPTION_SUPER_TOKEN.deleteFlow(subscriber, address(this));
    }

    /// @inheritdoc ChannelBase
    function emergencyCloseStreams(address[] calldata subscribers) external override {
        if (!HOST.isAppJailed(ISuperApp(address(this)))) revert NOT_EMERGENCY();
        for (uint256 i = 0; i < subscribers.length; i++) {
            SUBSCRIPTION_SUPER_TOKEN.deleteFlow(subscribers[i], address(this));
        }
    }

    /// @inheritdoc ChannelBase
    function emergencyTransferTokens() external override {
        if (!HOST.isAppJailed(ISuperApp(address(this))) || msg.sender != owner) revert NOT_EMERGENCY();

        uint256 ethXBalance = SUBSCRIPTION_SUPER_TOKEN.balanceOf(address(this));
        SUBSCRIPTION_SUPER_TOKEN.transfer(msg.sender, ethXBalance);
    }

    function afterAgreementCreated(
        ISuperToken superToken,
        address agreementClass,
        bytes32, /*agreementId */
        bytes calldata agreementData,
        bytes calldata, /*cbdata*/
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        if (!_isHost()) revert NOT_SUPERFLUID_HOST();
        if (!_isAcceptedSuperToken(superToken)) revert NOT_ACCEPTED_TOKEN();
        if (!_isAcceptedAgreement(agreementClass)) return ctx;

        (address sender,) = abi.decode(agreementData, (address, address));
        // this is flowRate delta as the previous flow rate is 0
        int96 flowRate = SUBSCRIPTION_SUPER_TOKEN.getFlowRate(sender, address(this));

        // @note users must send a flow rate greater than or equal to the subscription flow rate
        if (flowRate < subscriptionFlowRate) revert INVALID_SUBSCRIPTION_FLOW_RATE();

        uint256 deposit = uint96(flowRate) * nativeAssetLiquidationPeriod;
        if (userDeposits[sender] < deposit) revert NOT_ENOUGH_DEPOSIT();

        newCtx = ctx;

        // sum the inflow rate from the new subscriber to the total inflow rate
        totalInflowRate += flowRate;

        // sum the inflow rate from the new subscriber to the globally tracked subscription inflow rate on the FAN token
        FAN.handleSubscribe(sender, flowRate);

        // when someone subscribes we immediately update the flow distribution
        int96 flowDistributionFlowRate =
            SUBSCRIPTION_SUPER_TOKEN.getFlowDistributionFlowRate(address(this), channelPool);
        if (flowDistributionFlowRate > 0) {
            newCtx = SUBSCRIPTION_SUPER_TOKEN.distributeFlowWithCtx(address(this), channelPool, totalInflowRate, newCtx);
        }

        // emit an event to indicate existence of a new subscriber for the subgraph
        emit Subscribed(sender, flowRate);
    }

    function afterAgreementUpdated(
        ISuperToken superToken,
        address agreementClass,
        bytes32, /*agreementId */
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        if (!_isHost()) revert NOT_SUPERFLUID_HOST();
        if (!_isAcceptedSuperToken(superToken)) revert NOT_ACCEPTED_TOKEN();
        if (!_isAcceptedAgreement(agreementClass)) return ctx;

        (address sender,) = abi.decode(agreementData, (address, address));
        int96 flowRate = SUBSCRIPTION_SUPER_TOKEN.getFlowRate(sender, address(this));

        // @note users must send a flow rate greater than or equal to the subscription flow rate
        if (flowRate < subscriptionFlowRate) revert INVALID_SUBSCRIPTION_FLOW_RATE();

        newCtx = ctx;

        (int96 previousFlowRate) = abi.decode(cbdata, (int96));

        int96 flowRateDelta = flowRate - previousFlowRate;

        totalInflowRate += flowRateDelta;

        // @note Get this from gov
        if (flowRateDelta > 0) {
            uint256 deposit = uint96(flowRateDelta) * nativeAssetLiquidationPeriod;
            if (userDeposits[sender] < deposit) {
                revert NOT_ENOUGH_DEPOSIT();
            }
        }

        // sum the flow rate delta after the subscription stream amount is updated
        FAN.handleSubscribe(sender, flowRateDelta);

        // when someone updates the amount of flow, we immediately update the flow distribution
        int96 flowDistributionFlowRate =
            SUBSCRIPTION_SUPER_TOKEN.getFlowDistributionFlowRate(address(this), channelPool);
        if (flowDistributionFlowRate >= 0) {
            newCtx = SUBSCRIPTION_SUPER_TOKEN.distributeFlowWithCtx(address(this), channelPool, totalInflowRate, newCtx);
        }

        emit SubscriptionUpdated(sender, previousFlowRate, flowRate);
    }

    function afterAgreementTerminated(
        ISuperToken superToken,
        address agreementClass,
        bytes32, /*agreementId*/
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        // @note this revert is okay because only the official host can jail this app
        if (!_isHost()) revert NOT_SUPERFLUID_HOST();

        // we're not allowed to revert in this callback, thus just return ctx on failing checks
        if (!_isAcceptedAgreement(agreementClass) || !_isAcceptedSuperToken(superToken)) {
            return ctx;
        }

        (address sender,) = abi.decode(agreementData, (address, address));

        // reset the user deposit to 0 so they need to redeposit to create a new flows
        userDeposits[sender] = 0;

        newCtx = ctx;

        ISuperfluid.Context memory context = HOST.decodeCtx(newCtx);

        (int96 previousFlowRate) = abi.decode(cbdata, (int96));

        // subtract the previous flow rate from the total inflow rate
        totalInflowRate -= previousFlowRate;

        // subtract the previous flow rate from the globally tracked subscription inflow rate on the FAN token
        FAN.updateTotalSubscriptionFlowRate(-previousFlowRate);

        // we update the GDA flow distribution to the protocol, owner and subscribers
        // only if an existing flow exists
        if (totalInflowRate >= 0) {
            newCtx = SUBSCRIPTION_SUPER_TOKEN.distributeFlowWithCtx(address(this), channelPool, totalInflowRate, newCtx);
        }

        // emit an event to indicate subscriber unsubscribing for the subgraph
        emit Unsubscribed(sender, context.msgSender, previousFlowRate);
    }

    function beforeAgreementUpdated(
        ISuperToken superToken,
        address agreementClass,
        bytes32, /*agreementId*/
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view override returns (bytes memory cbdata) {
        if (!_isHost()) revert NOT_SUPERFLUID_HOST();
        if (!_isAcceptedSuperToken(superToken)) revert NOT_ACCEPTED_TOKEN();
        if (!_isAcceptedAgreement(agreementClass)) return ctx;

        (address sender, address receiver) = abi.decode(agreementData, (address, address));
        (, int96 flowRate,,) = superToken.getFlowInfo(sender, receiver);

        return abi.encode(flowRate);
    }

    function beforeAgreementTerminated(
        ISuperToken superToken,
        address agreementClass,
        bytes32, /*agreementId*/
        bytes calldata agreementData,
        bytes calldata /*ctx*/
    ) external view override returns (bytes memory cbdata) {
        // we're not allowed to revert in this callback, thus just return empty cbdata on failing checks
        if (!_isHost() || !_isAcceptedAgreement(agreementClass) || !_isAcceptedSuperToken(superToken)) {
            return cbdata;
        }

        (address sender, address receiver) = abi.decode(agreementData, (address, address));
        (, int96 flowRate,,) = superToken.getFlowInfo(sender, receiver);

        return abi.encode(flowRate);
    }

    function getSubscriberFlowInfo(address subscriber)
        external
        view
        override
        returns (uint256 lastUpdated, int96 flowRate)
    {
        (lastUpdated, flowRate,,) = SUBSCRIPTION_SUPER_TOKEN.getFlowInfo(subscriber, address(this));
    }

    function getSubscriberCashbackPercentage() public view override returns (uint256) {
        return ONE_HUNDRED_PERCENT - creatorFeePercentage - PROTOCOL_FEE_AMOUNT;
    }

    function _getCurrentPoolUnits(address subscriber)
        internal
        view
        returns (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentSubscriberUnits)
    {
        currentProtocolPoolUnits = channelPool.getUnits(PROTOCOL_FEE_DESTINATION);
        currentCreatorPoolUnits = channelPool.getUnits(owner);
        currentSubscriberUnits = channelPool.getUnits(subscriber);
    }

    function _isHost() internal view returns (bool) {
        return msg.sender == address(HOST);
    }

    function _isAcceptedAgreement(address agreementClass) internal view returns (bool) {
        return agreementClass == address(HOST.getAgreementClass(CFAV1_TYPE));
    }

    function _isAcceptedSuperToken(ISuperToken superToken) internal view returns (bool) {
        return address(superToken) == address(SUBSCRIPTION_SUPER_TOKEN);
    }
}
