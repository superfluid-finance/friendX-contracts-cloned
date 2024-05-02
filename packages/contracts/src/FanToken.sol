// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20Upgradeable } from "@openzeppelin-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { ERC1967Upgrade } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Upgrade.sol";

import { IFanToken, SubscriberCreatorChannelData, SubscriberData } from "./interfaces/IFanToken.sol";
import { IChannelFactory } from "./interfaces/IChannelFactory.sol";
import { ChannelBase } from "./interfaces/ChannelBase.sol";

/// INVARIANTS NOTE
/// sum of all staked balances for all subscribers
/// == sum of all staked balances for all creator channels
/// == totalStaked

/// some invariants surrounding the equations for the distribution schedule

/// @title Fan Token Contract
/// @author Superfluid
/// @notice This is the rewards token for the OnlyFrens system and includes logic for
///         the rewards distribution as well as the upgradeability mechanism.
/// @dev This will act as the logic contract for an upgradeable proxy.
contract FanToken is ERC20Upgradeable, ERC1967Upgrade, IFanToken {
    //// CONSTANT VARIABLES ////
    uint256 public constant UNSTAKE_COOLDOWN_PERIOD = 1 days;

    //// STATE VARIABLES ////
    /// @notice The subscriber-channel data, including: tokens staked, last rewards claim time
    mapping(address subscriber => mapping(address channel => SubscriberCreatorChannelData data)) internal
        _subscriberCreatorChannelData;

    /// @notice The amount of FAN tokens staked for a particular creator channel
    mapping(address channel => uint256 totalStaked) internal _channelStakedBalances;

    mapping(address subscriber => SubscriberData data) internal _subscriberData;

    /// @notice The total amount of FAN tokens staked for all creator channels
    uint256 public totalStaked;

    /// @notice The total subscription flow rate for all creator channels
    /// @dev Invariant: this number should never go below 0
    int256 public totalSubscriptionInflowRate;

    IChannelFactory public channelFactory;
    address public owner;
    uint256 public startTime;
    uint256 public rewardDuration;
    uint256 public multiplier;
    uint256 public flowBasedRewardsPercentage;
    uint256 public stakedBasedRewardsPercentage;

    //// MODIFIERS ////
    modifier checkIsChannelCreated(address channel) {
        if (!channelFactory.isChannelCreated(channel)) revert FAN_TOKEN_INVALID_CREATOR_CHANNEL();
        _;
    }

    modifier checkIsUnstakeCooldownOver() {
        if (!_isUnstakeCooldownOver(msg.sender)) revert FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER();
        _;
    }

    //// FUNCTIONS ////
    constructor() ERC20Upgradeable() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint256 _rewardDuration,
        uint256 _multiplier,
        uint256 _flowBasedRewardsPercentage,
        uint256 _stakedBasedRewardsPercentage
    ) external initializer {
        __ERC20_init("Alfa Token", "ALFA");
        startTime = block.timestamp;
        owner = _owner;
        rewardDuration = _rewardDuration;
        multiplier = _multiplier;
        flowBasedRewardsPercentage = _flowBasedRewardsPercentage;
        stakedBasedRewardsPercentage = _stakedBasedRewardsPercentage;

        if (flowBasedRewardsPercentage + stakedBasedRewardsPercentage != 10000) {
            revert FAN_TOKEN_INVALID_REWARDS_PERCENTAGE();
        }

        // mint max amount of reward token to this address
        _mint(address(this), type(uint256).max);
    }

    /// @inheritdoc IFanToken
    function setChannelFactory(address _channelFactory) external override {
        if (msg.sender != owner) revert FAN_TOKEN_ONLY_OWNER();

        channelFactory = IChannelFactory(_channelFactory);
    }

    function setOwner(address _owner) external {
        if (msg.sender != owner) revert FAN_TOKEN_ONLY_OWNER();

        owner = _owner;
    }

    function upgradeTo(address newImplementation) external {
        if (msg.sender != owner) revert FAN_TOKEN_ONLY_OWNER();

        _upgradeTo(newImplementation);
    }

    /// @inheritdoc IFanToken
    function updateTotalSubscriptionFlowRate(int96 flowRateDelta) external override checkIsChannelCreated(msg.sender) {
        totalSubscriptionInflowRate += flowRateDelta;
    }

    function ownerMint(address account, uint256 amount) external {
        if (msg.sender != owner) revert FAN_TOKEN_ONLY_OWNER();

        // @note moving FAN from this contract to account
        _move(address(this), account, amount);
    }

    /// @inheritdoc IFanToken
    function handleSubscribe(address subscriber, int96 flowRateDelta)
        external
        override
        checkIsChannelCreated(msg.sender)
    {
        totalSubscriptionInflowRate += flowRateDelta;

        // @note when someone subscribes to a channel, we need to update the last claimed time
        // this is because getClaimableAmount calculates
        _subscriberCreatorChannelData[subscriber][msg.sender].lastClaimedTime = block.timestamp;
    }

    /// @inheritdoc IFanToken
    function stake(address channel, uint256 amount) external override checkIsChannelCreated(channel) {
        // can be unchecked because of FAN_TOKEN_INSUFFICIENT_FAN_BALANCE check
        // user is moving their balance to this contract when staking
        _move(msg.sender, address(this), amount);

        // @note The `amount` staked will differ from the units granted to the user
        // due to scaling factor to ensure that a distribution flow is always being
        // sent
        _stake(channel, amount);
    }

    /// @inheritdoc IFanToken
    function unstake(address channel, uint256 amount) external override checkIsChannelCreated(channel) {
        if (_subscriberCreatorChannelData[msg.sender][channel].stakedBalance < amount) {
            revert FAN_TOKEN_INSUFFICIENT_STAKED_FAN_BALANCE();
        }

        // unstaked balance goes to user
        // this contract is sending balance back to the user when unstaking
        _move(address(this), msg.sender, amount);

        _unstake(channel, amount);

        ChannelBase(channel).handleUnstake(msg.sender, amount);
    }

    /// @inheritdoc IFanToken
    function claim(address channel) public override checkIsChannelCreated(channel) {
        uint256 claimableAmount = _claim(channel);

        // user claims FAN token to their balance
        _move(address(this), msg.sender, claimableAmount);
    }

    function decimals() public pure override returns (uint8) {
        // @note TODO: change to 8 decimal places
        return 14;
    }

    /// @inheritdoc IFanToken
    function compound(address channel) public override checkIsChannelCreated(channel) {
        uint256 claimableAmount = _claim(channel);

        // directly move the claimable amount to staked balance
        // we do not move it to the users balance first
        _stake(channel, claimableAmount);
    }

    /// @inheritdoc IFanToken
    function claimAll(address[] calldata channels) external {
        for (uint256 i = 0; i < channels.length; i++) {
            claim(channels[i]);
        }
    }

    /// @inheritdoc IFanToken
    function compoundAll(address[] calldata channels) external {
        for (uint256 i = 0; i < channels.length; i++) {
            compound(channels[i]);
        }
    }

    /// @inheritdoc IFanToken
    function stakedBalanceOf(address subscriber, address channel) external view override returns (uint256) {
        return _subscriberCreatorChannelData[subscriber][channel].stakedBalance;
    }

    /// @inheritdoc IFanToken
    function channelStakedBalanceOf(address channel) external view override returns (uint256) {
        return _channelStakedBalances[channel];
    }

    /// @inheritdoc IFanToken
    function getSubscriberData(address subscriber) external view override returns (SubscriberData memory) {
        return _subscriberData[subscriber];
    }

    /// @inheritdoc IFanToken
    function getSubscriberCreatorChannelData(address subscriber, address channel)
        external
        view
        override
        returns (SubscriberCreatorChannelData memory)
    {
        return _subscriberCreatorChannelData[subscriber][channel];
    }

    function balanceOf(address account)
        public
        view
        virtual
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        return _subscriberData[account].balance;
    }

    /// @inheritdoc IFanToken
    function getTotalRewardsDistribution() public view override returns (uint256) {
        return _getTotalRewards(totalSubscriptionInflowRate);
    }

    /// @inheritdoc IFanToken
    function getChannelRewards(address channel) public view override returns (uint256 channelRewards) {
        channelRewards =
            _getChannelRewards(channel, totalSubscriptionInflowRate, ChannelBase(channel).totalInflowRate());
    }

    /// @inheritdoc IFanToken
    function getDailyMaxClaimableAmount(address subscriber, address channel)
        public
        view
        override
        returns (uint256 claimableAmount)
    {
        int96 channelInflowRate = ChannelBase(channel).totalInflowRate();
        (, int96 subscriberFlowRate) = ChannelBase(channel).getSubscriberFlowInfo(subscriber);

        claimableAmount =
            _getDailyMaxClaimableAmount(channel, totalSubscriptionInflowRate, channelInflowRate, subscriberFlowRate);
    }

    /// @inheritdoc IFanToken
    function estimateDailyMaxClaimableAmount(
        address subscriber,
        address channel,
        int256 totalFlowRate,
        int96 channelTotalInflowRate,
        int96 subscriptionFlowRate
    ) public view override returns (uint256 claimableAmount) {
        return _getDailyMaxClaimableAmount(channel, totalFlowRate, channelTotalInflowRate, subscriptionFlowRate);
    }

    /// @inheritdoc IFanToken
    function getClaimableAmount(address subscriber, address channel)
        public
        view
        override
        returns (uint256 claimableAmount)
    {
        // @note if the claim cooldown or unstake cooldown is not over, then the claimable amount is 0
        if (!_isUnstakeCooldownOver(subscriber)) {
            return 0;
        }

        uint256 dailyMaxClaimableAmount = getDailyMaxClaimableAmount(subscriber, channel);

        uint256 timeElapsed = block.timestamp - _subscriberCreatorChannelData[subscriber][channel].lastClaimedTime;
        uint256 timeElapsedClaimableAmount = (dailyMaxClaimableAmount * timeElapsed) / 1 days;

        // @note We cap the claimable amount to the daily claimable amount
        return
            dailyMaxClaimableAmount > timeElapsedClaimableAmount ? timeElapsedClaimableAmount : dailyMaxClaimableAmount;
    }

    /// @inheritdoc IFanToken
    function getTotalClaimableAmount(address subscriber, address[] calldata channels)
        external
        view
        override
        returns (uint256 totalClaimableAmount, address[] memory claimableChannels)
    {
        if (!_isUnstakeCooldownOver(subscriber)) return (totalClaimableAmount, claimableChannels);

        claimableChannels = new address[](channels.length);
        uint256 currentIndex;
        for (uint256 i = 0; i < channels.length; i++) {
            uint256 claimableAmount = getClaimableAmount(subscriber, channels[i]);
            totalClaimableAmount += claimableAmount;
            if (claimableAmount > 0) {
                claimableChannels[currentIndex] = channels[i];
                currentIndex++;
            }
        }
    }

    /// @inheritdoc IFanToken
    function getTotalDailyMaxClaimableAmount(address subscriber, address[] calldata channels)
        external
        view
        override
        returns (uint256 totalDailyMaxClaimableAmount)
    {
        for (uint256 i = 0; i < channels.length; i++) {
            totalDailyMaxClaimableAmount += getDailyMaxClaimableAmount(subscriber, channels[i]);
        }
    }

    function getClaimableAmount(address channel) public view returns (uint256 claimableAmount) {
        return getClaimableAmount(msg.sender, channel);
    }

    function _mint(address account, uint256 amount) internal virtual override {
        // @note TODO this is currently extremely gas inefficient because we are updating
        // storage for _balances which we are not using at all.
        super._mint(account, amount);
        unchecked {
            _subscriberData[account].balance += amount;
        }
    }

    function _claim(address channel) internal returns (uint256 claimableAmount) {
        claimableAmount = getClaimableAmount(channel);

        _subscriberCreatorChannelData[msg.sender][channel].lastClaimedTime = block.timestamp;

        emit FanTokenClaimed(msg.sender, channel, claimableAmount);
    }

    function _stake(address channel, uint256 amount) internal checkIsUnstakeCooldownOver {
        // increment the global amount of FAN staked for the rewards calculation
        totalStaked += amount;

        // increment the staked amount of FAN staked for a particular creator channel for the rewards calculation
        _channelStakedBalances[channel] += amount;

        // increment the staked balance to a creator channel for a subscriber for staking
        _subscriberCreatorChannelData[msg.sender][channel].stakedBalance += amount;

        emit FanTokenStaked(msg.sender, channel, amount);

        // Handles update of creator channel GDA pool units and starting a flow distribution
        // see ChannelBase for more details
        ChannelBase(channel).handleStake(msg.sender, amount);
    }

    function _unstake(address channel, uint256 amount) internal {
        // update the last unstaked time for the subscriber to ensure that the unstake cooldown comes into effect
        _subscriberData[msg.sender].lastUnstakedTime = block.timestamp;

        // decrement the global amount of FAN staked for the rewards calculation
        totalStaked -= amount;

        // decrement the staked amount of FAN staked for a particular creator channel for the rewards calculation
        _channelStakedBalances[channel] -= amount;

        // decrement the staked balance to a creator channel for a subscriber for unstaking
        _subscriberCreatorChannelData[msg.sender][channel].stakedBalance -= amount;

        emit FanTokenUnstaked(msg.sender, channel, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (_subscriberData[from].balance < amount) revert FAN_TOKEN_INSUFFICIENT_FAN_BALANCE();

        unchecked {
            _subscriberData[from].balance -= amount;
            _subscriberData[to].balance += amount;
        }
    }

    function _transfer(address, /*from*/ address, /*to*/ uint256 /*amount*/ ) internal pure override {
        revert FAN_TOKEN_TRANSFER_DISABLED();
    }

    function _isUnstakeCooldownOver(address subscriber) internal view returns (bool) {
        return block.timestamp - _subscriberData[subscriber].lastUnstakedTime > UNSTAKE_COOLDOWN_PERIOD;
    }

    function _getTotalRewards(int256 totalFlowRate) internal view returns (uint256) {
        uint256 timeDelta = block.timestamp - startTime;
        uint256 realtimeMultiplier =
            timeDelta < rewardDuration ? (rewardDuration - timeDelta) * multiplier / rewardDuration : 0;

        UpgradeableBeacon channelBeacon = channelFactory.CHANNEL_BEACON();
        uint256 oneHundredPercent = ChannelBase(channelBeacon.implementation()).ONE_HUNDRED_PERCENT();
        // or we could hardcode... ONE_HUNDRED_PERCENT = 10_000

        return realtimeMultiplier == 0
            ? uint256(totalFlowRate)
            : realtimeMultiplier * uint256(totalFlowRate) / oneHundredPercent;
    }

    function _getChannelRewards(address channel, int256 totalFlowRate, int96 channelTotalInflowRate)
        internal
        view
        returns (uint256 channelRewards)
    {
        uint256 totalRewards = _getTotalRewards(totalFlowRate);
        uint256 channelStakedBalance = _channelStakedBalances[channel];
        // @note use the if (totalStaked == 0) formula
        // as the base amount of channel rewards and the other block as boosted rewards
        // @note we need to block sybil attack farming of FAN as well
        uint256 totalFlowRateBasedRewards = totalRewards * flowBasedRewardsPercentage / 10000;
        uint256 totalStakedBasedRewards = totalRewards * stakedBasedRewardsPercentage / 10000;

        uint256 channelFlowBasedRewards = totalFlowRate == 0
            ? 0
            : (totalFlowRateBasedRewards * uint256(int256(channelTotalInflowRate))) / uint256(int256(totalFlowRate));

        uint256 channelStakedBasedRewards =
            totalStaked == 0 ? 0 : (totalStakedBasedRewards * channelStakedBalance) / totalStaked;

        channelRewards = channelFlowBasedRewards + channelStakedBasedRewards;
    }

    function _getDailyMaxClaimableAmount(
        address channel,
        int256 totalFlowRate,
        int96 channelTotalInflowRate,
        int96 subscriptionFlowRate
    ) internal view returns (uint256) {
        // get the FAN allocated to the channel based on either the channel subscription flow rate vs. global subscription flow rate
        // or the staked balance of the channel vs. global staked balance
        uint256 channelRewards = _getChannelRewards(channel, totalFlowRate, channelTotalInflowRate);

        uint256 channelInflowRate = uint256(int256(channelTotalInflowRate));

        // get the claimable FAN amount based on the subscriber's flow rate vs. the channel's flow rate
        return channelInflowRate == 0
            ? uint256(0)
            : (channelRewards * uint256(int256(subscriptionFlowRate))) / channelInflowRate;
    }
}
