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
    ISuperToken,
    PoolConfig
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {
    SuperfluidGovernanceBase
} from "@superfluid-finance/ethereum-contracts/contracts/gov/SuperfluidGovernanceBase.sol";
import {
    SuperTokenV1Library
} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { ChannelBase } from "./interfaces/ChannelBase.sol";
import { IFanToken } from "./interfaces/IFanToken.sol";
import { AccountingHelperLibrary, ONE_HUNDRED_PERCENT } from "./libs/AccountingHelperLibrary.sol";


using SafeCast for uint256;
using SuperTokenV1Library for ISuperToken;

/// @title Channel
/// @author Superfluid
/// @notice This contract represents a channel that can be subscribed to by fans
/// @dev This contract is a SuperApp that reacts to CFAv1 flows
contract Channel is ChannelBase {

    bytes32 internal constant _CFAV1_TYPE = keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");

    /// @dev This limits the amount of distributeLeakedRewards after the leakage had be fixed.
    uint256 internal constant _MINIMUM_INSTANT_DISTRIBUTION_AMOUNT = 1e18;

    //// FUNCTIONS ////
    constructor(ISuperfluid host,
                ISuperToken ethX, IFanToken fan,
                address protocolFeeDest, uint256 protocolFeeAmount,
                int96 minSubscriptionFlowRate, int96 maxSubscriptionFlowRate)
        ChannelBase(host,
                    ethX, fan,
                    protocolFeeDest, protocolFeeAmount,
                    minSubscriptionFlowRate, maxSubscriptionFlowRate)
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

        // NOTE: we use these flow rates "190258751902587", "380517503805175", "570776255707762", otherwise.
        require(_flowRate >= MINIMUM_SUBSCRIPTION_FLOW_RATE &&
                _flowRate <= MAXIMUM_SUBSCRIPTION_FLOW_RATE, "Invalid subscription flow rate");

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
        stakerRegimeRevisions[_owner] = LATEST_REGIME_REVISION;

        // set the creator fee percentage
        creatorFeePercentage = creatorFeePct;

        // make sure the new channels is always of the latest regime
        currentRegimeRevision = LATEST_REGIME_REVISION;

        // make sure protocol fee destination has also the latest regime revision
        stakerRegimeRevisions[PROTOCOL_FEE_DESTINATION] = LATEST_REGIME_REVISION;
    }

    /// @inheritdoc ChannelBase
    function handleStake(address staker, uint256 stakeDelta) external override onlyFans {
        distributeLeakedRewards();
        _upgradeStakerIfNeeded(staker);

        // Get the amount of units that will be allocated to the protocol fee destination, creator and staker
        // based on the stakeDelta
        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 stakerUnitsDelta) =
            AccountingHelperLibrary.getPoolUnitDeltaAmounts(_channelPoolScalingFactor(staker),
                                                            stakeDelta, PROTOCOL_FEE_AMOUNT, creatorFeePercentage);

        uint256 cashbackPercentage = getStakersCashbackPercentage();

        if (stakerUnitsDelta == 0 && cashbackPercentage > 0) revert NO_UNITS_FOR_SUBSCRIBER();

        (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentStakerUnits) =
            _getCurrentPoolUnits(staker);

        // rebalance the protocol fee units and the creator units so that they are in the correct proportions
        channelPool.updateMemberUnits(PROTOCOL_FEE_DESTINATION, currentProtocolPoolUnits + protocolFeeUnitsDelta);

        // handle the case where the owner is subscribing to their own channel
        if (staker == owner) {
            // give the owner-staker the creator units and the staker units
            channelPool.updateMemberUnits(staker, currentCreatorPoolUnits + creatorUnitsDelta + stakerUnitsDelta);
        } else {
            // the staker is not the owner, so we need to update their units separately
            channelPool.updateMemberUnits(owner, currentCreatorPoolUnits + creatorUnitsDelta);
            // if the cashback percentage is 0, there is nothing to update for the staker
            if (cashbackPercentage > 0) {
                channelPool.updateMemberUnits(staker, currentStakerUnits + stakerUnitsDelta);
            }
        }
    }

    /// @inheritdoc ChannelBase
    function handleUnstake(address staker, uint256 unstakeDelta) external override onlyFans {
        distributeLeakedRewards();
        _upgradeStakerIfNeeded(staker);

        (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentStakerUnits) =
            _getCurrentPoolUnits(staker);

        uint256 cashbackPercentage = getStakersCashbackPercentage();

        // if the staker has no units, they have deleted their flow, so unstaking should not impact
        // the unit amounts for the different accounts as this has been handled in the onFlowDeleted callback
        if (currentStakerUnits == 0 && cashbackPercentage > 0) return;

        // Get the amount of units that will be unallocated from the protocol fee destination, creator and staker
        // based on the unstakeDelta
        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 stakerUnitsDelta) =
            AccountingHelperLibrary.getPoolUnitDeltaAmounts(_channelPoolScalingFactor(staker),
                                                            unstakeDelta, PROTOCOL_FEE_AMOUNT, creatorFeePercentage);

        // rebalance the protocol fee units and the creator units so that they are in the correct proportions
        channelPool.updateMemberUnits(PROTOCOL_FEE_DESTINATION,
                                      _safeSub(currentProtocolPoolUnits, protocolFeeUnitsDelta));

        // handle the case where the owner is unsubscribing from their own channel
        if (staker == owner) {
            // remove the creator units and staker units from the owner-staker
            channelPool.updateMemberUnits(staker,
                                          _safeSub(currentCreatorPoolUnits, creatorUnitsDelta + stakerUnitsDelta));
        } else {
            // the staker is not the owner, so we need to update their units separately
            channelPool.updateMemberUnits(owner, _safeSub(currentCreatorPoolUnits, creatorUnitsDelta));
            // if the cashback percentage is 0, there is nothing to update for the staker
            if (cashbackPercentage > 0) {
                channelPool.updateMemberUnits(staker, _safeSub(currentStakerUnits, stakerUnitsDelta));
            }
        }
    }

    /// @dev !WARNING! This is an open-to-all action intended to fix the early-day leaked channel inflow issue.
    ///      It is safe to be called by everyone, because it distribute to CO, Stakers with the same proportion.
    function distributeLeakedRewards() public {
        distributeLeakedRewards(_MINIMUM_INSTANT_DISTRIBUTION_AMOUNT);
    }

    /// @dev This allows forcing minimumAmount to 0 during scripted cleanups.
    function distributeLeakedRewards(uint256 minimumAmount) public {
        (, int96 _actualFeeDistFlowRate,) = SUBSCRIPTION_SUPER_TOKEN.getGDAFlowInfo(address(this), channelPool);
        if (totalInflowRate > _actualFeeDistFlowRate) {
            uint256 reservedForExtraBuffer = SUBSCRIPTION_SUPER_TOKEN.getBufferAmountByFlowRate(totalInflowRate)
                - SUBSCRIPTION_SUPER_TOKEN.getBufferAmountByFlowRate(_actualFeeDistFlowRate);
            uint256 balance = SUBSCRIPTION_SUPER_TOKEN.balanceOf(address(this));
            if (balance > reservedForExtraBuffer) {
                uint256 toBeDistributed = balance - reservedForExtraBuffer;
                if (toBeDistributed > minimumAmount) {
                    SUBSCRIPTION_SUPER_TOKEN.distributeToPool(address(this), channelPool, toBeDistributed);
                }
            }
        } // else this should not happen
    }

    // @dev !WARNING! Similar to distributeLeakedRewards, this is an open-to-all action, too.
    function distributeTotalInFlows() public {
        if (totalInflowRate >= 0) {
            SUBSCRIPTION_SUPER_TOKEN.distributeFlow(address(this), channelPool, totalInflowRate);
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

        if (totalInflowRate >= 0) {
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

        if (totalInflowRate >= 0) {
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

    function getStakersCashbackPercentage() public view override returns (uint256) {
        return ONE_HUNDRED_PERCENT - creatorFeePercentage - PROTOCOL_FEE_AMOUNT;
    }

    // This is used where rounding-errors-resulted error could cause underflow issue
    function _safeSub(uint128 a, uint128 b) internal pure returns (uint128 c) {
        if (a > b) return a - b;
        else return 0;
    }

    function _getCurrentPoolUnits(address staker)
        internal
        view
        returns (uint128 currentProtocolPoolUnits, uint128 currentCreatorPoolUnits, uint128 currentStakerUnits)
    {
        currentProtocolPoolUnits = channelPool.getUnits(PROTOCOL_FEE_DESTINATION);
        currentCreatorPoolUnits = channelPool.getUnits(owner);
        currentStakerUnits = channelPool.getUnits(staker);
    }

    function _isHost() internal view returns (bool) {
        return msg.sender == address(HOST);
    }

    function _isAcceptedAgreement(address agreementClass) internal view returns (bool) {
        return agreementClass == address(HOST.getAgreementClass(_CFAV1_TYPE));
    }

    function _isAcceptedSuperToken(ISuperToken superToken) internal view returns (bool) {
        return address(superToken) == address(SUBSCRIPTION_SUPER_TOKEN);
    }

    function _channelPoolScalingFactor(address staker) internal view returns (uint256) {
        uint256 revision = stakerRegimeRevisions[staker];
        if (revision == 0) return CHANNEL_POOL_SCALING_FACTOR_R0;
        else if (revision == 1) return CHANNEL_POOL_SCALING_FACTOR_R1;
        else assert(false);
    }

    function _upgradeStakerIfNeeded(address staker) internal {
        // check if the migration has started
        if (currentRegimeRevision == LATEST_REGIME_REVISION) {
            // staker needs to be migrated
            if (stakerRegimeRevisions[staker] == LATEST_REGIME_REVISION - 1) {
                uint128 stakerUnit = channelPool.getUnits(staker);
                // Note: leave the one unit allow, that is the special default channel owner total units.
                if (stakerUnit > 1) {
                    uint128 newStakerUnit = (uint256(stakerUnit) * CHANNEL_POOL_SCALING_FACTOR_R0
                                             / CHANNEL_POOL_SCALING_FACTOR_R1).toUint128();
                    channelPool.updateMemberUnits(staker, newStakerUnit);
                }
            }
            // allways make sure we set the staker to the latest regime
            stakerRegimeRevisions[staker] = LATEST_REGIME_REVISION;
        }
    }

    //// Government Interventions: "We are here to help!" ////

    function govMarkRegimeUpgradeStarted() external onlyGov {
        require(currentRegimeRevision == LATEST_REGIME_REVISION - 1, "channel already of latest regime");
        currentRegimeRevision = LATEST_REGIME_REVISION;
        // the owner and platform fee destination must be migrated right away, otherwise all hell can break loose
        _upgradeStakerIfNeeded(owner);
        _upgradeStakerIfNeeded(PROTOCOL_FEE_DESTINATION);
    }

    function govUpgradeStakers(address[] memory stakers) external onlyGov {
        for (uint256 i = 0; i < stakers.length; i++) {
            _upgradeStakerIfNeeded(stakers[i]);
        }
    }

    //// MODIFIERS ////
    modifier onlyFans() {
        if (msg.sender != address(FAN)) revert ONLY_FAN_CAN_BE_CALLER();
        _;
    }

    modifier onlyGov() {
        if (msg.sender != FAN.owner()) revert ONLY_GOV_ALLOWED();
        _;
    }

    /// @dev !!WARNING!! A production version of the FanToken requires this interface, do not delete without verifying
    //        with a fork testing.
    function ONE_HUNDRED_PERCENT() external pure returns (uint256) { return ONE_HUNDRED_PERCENT; }
}
