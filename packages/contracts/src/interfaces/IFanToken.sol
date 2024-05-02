// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import { IERC20Upgradeable } from "@openzeppelin-upgradeable/token/ERC20/IERC20Upgradeable.sol";

struct SubscriberCreatorChannelData {
    uint256 stakedBalance;
    uint256 lastClaimedTime;
}

struct SubscriberData {
    uint256 balance;
    uint256 lastUnstakedTime;
}

interface IFanToken is IERC20Upgradeable {
    ///// EVENTS /////
    event FanTokenStaked(address indexed subscriber, address indexed channel, uint256 amount);
    event FanTokenUnstaked(address indexed subscriber, address indexed channel, uint256 amount);
    event FanTokenClaimed(address indexed subscriber, address indexed channel, uint256 amount);

    ///// CUSTOM ERRORS /////
    error FAN_TOKEN_INVALID_CREATOR_CHANNEL();          // 0x26093923
    error FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER();        // 0x04361915
    error FAN_TOKEN_TRANSFER_DISABLED();                // 0x31deee11
    error FAN_TOKEN_INSUFFICIENT_FAN_BALANCE();         // 0x87b4be33
    error FAN_TOKEN_INSUFFICIENT_STAKED_FAN_BALANCE();  // 0x863999dc
    error FAN_TOKEN_INVALID_REWARDS_PERCENTAGE();       // 0xa31e2b39
    error FAN_TOKEN_ONLY_OWNER();                       // 0x8483e25d

    ///// WRITE FUNCTIONS /////
    /// @notice Sets the channel factory address
    /// @dev Updates the address of the channel factory used in the contract
    /// @param channelFactory The address of the new channel factory
    function setChannelFactory(address channelFactory) external;

    /// @notice Updates the totalSubscriptionFlowRate property when a new subscription is created or cancelled
    /// @dev Only channels created via the ChannelFactory can call this
    function updateTotalSubscriptionFlowRate(int96 flowRateDelta) external;
    
    /// @notice Updates the totalSubscriptionFlowRate and lastClaimedTime property when a new subscription is created 
    /// @dev Only channels created via the ChannelFactory can call this
    /// @param subscriber The address of the subscriber
    /// @param flowRateDelta The change in the subscriber's flow rate
    function handleSubscribe(address subscriber, int96 flowRateDelta) external;

    /// @notice Allows a user to stake tokens in a channel
    /// @dev Stakes a specified amount of tokens in the given channel
    /// @param channel The address of the channel where tokens are to be staked
    /// @param amount The amount of tokens to be staked
    function stake(address channel, uint256 amount) external;

    /// @notice Allows a user to unstake tokens from a channel
    /// @dev Unstakes a specified amount of tokens from the given channel
    /// @param channel The address of the channel from which tokens are to be unstaked
    /// @param amount The amount of tokens to be unstaked
    function unstake(address channel, uint256 amount) external;

    /// @notice Compounds rewards in a channel
    /// @dev Automatically claims and stakes claimable rewards for the specified channel
    /// @param channel The address of the channel where rewards are to be compounded
    function compound(address channel) external;

    /// @notice Claims accrued rewards from a channel
    /// @dev Allows a user to claim their rewards from the specified channel
    /// @param channel The address of the channel from which rewards are to be claimed
    function claim(address channel) external;

    /// @notice Claims accrued rewards from multiple channels
    /// @dev Allows a user to claim their rewards from multiple channels
    /// @param channels The addresses of the channels from which rewards are to be claimed
    function claimAll(address[] memory channels) external;

    /// @notice Compounds rewards in multiple channels
    /// @dev Automatically claims and stakes claimable rewards for the specified channels
    /// @param channels The addresses of the channels where rewards are to be compounded
    function compoundAll(address[] memory channels) external;

    ///// VIEW FUNCTIONS /////
    /// @notice Retrieves the staked balance of a subscriber in a specific channel
    /// @dev Returns the amount of tokens staked by a subscriber in a given channel
    /// @param subscriber The address of the subscriber
    /// @param channel The address of the channel
    /// @return The staked balance of the subscriber in the specified channel
    function stakedBalanceOf(address subscriber, address channel) external view returns (uint256);

    /// @notice Gets the total staked balance in a channel
    /// @dev Returns the total amount of tokens staked in the specified channel
    /// @param channel The address of the channel
    /// @return The total staked balance in the specified channel
    function channelStakedBalanceOf(address channel) external view returns (uint256);

    /// @notice Retrieves subscriber data
    /// @dev Returns the data associated with a subscriber
    /// @param subscriber The address of the subscriber
    /// @return Subscriber data in memory
    function getSubscriberData(address subscriber) external view returns (SubscriberData memory);

    /// @notice Fetches data related to a subscriber and a specific channel
    /// @dev Returns detailed data about a subscriber's interactions with a given channel
    /// @param subscriber The address of the subscriber
    /// @param channel The address of the channel
    /// @return Data specific to the subscriber and the channel in memory
    function getSubscriberCreatorChannelData(address subscriber, address channel)
        external
        view
        returns (SubscriberCreatorChannelData memory);

    /// @notice Returns the total rewards that are available to be distributed amongst all channels and subscribers
    /// @dev This is a function based on the total inflow rate and rewards earlier users
    /// @return The total rewards that are available to be distributed
    function getTotalRewardsDistribution() external view returns (uint256);

    /// @notice Returns the rewards that are available to be distributed subscribers of a channel
    /// @dev This is based on the total subscription inflow rate of the channel in proportion to the global inflow rate
    /// @param channel The address of the channel
    /// @return channelRewards The rewards that are available to be distributed to subscribers of the channel
    function getChannelRewards(address channel) external view returns (uint256 channelRewards);

    /// @notice Calculates the daily max claimable amount for a subscriber in a channel
    /// @dev Even if a user doesn't claim for 24 hours and 1 second, they can only claim 24 hours worth of rewards
    /// @param subscriber The address of the subscriber
    /// @param channel The address of the channel
    /// @return claimableAmount The amount that can be claimed by the subscriber
    function getDailyMaxClaimableAmount(address subscriber, address channel)
        external
        view
        returns (uint256 claimableAmount);
    
    /// @notice Estimates the daily max claimable amount for a 
    /// @dev Even if a user doesn't claim for 24 hours and 1 second, they can only claim 24 hours worth of rewards
    /// @param subscriber The address of the subscriber
    /// @param channel The address of the channel
    /// @param totalFlowRate The total flow rate of the token
    /// @param channelTotalInflowRate The total inflow rate of the channel
    /// @param subscriptionFlowRate The flow rate of the subscriber
    /// @return claimableAmount The estimated amount that can be claimed by the subscriber given the inputs
    function estimateDailyMaxClaimableAmount(
        address subscriber,
        address channel,
        int256 totalFlowRate,
        int96 channelTotalInflowRate,
        int96 subscriptionFlowRate
    ) external view returns (uint256 claimableAmount);

    /// @notice Calculates the claimable amount for a subscriber in a channel
    /// @dev This considers the amount of time since the last claim as rewards are accrued over 24 hours
    /// @param subscriber The address of the subscriber
    /// @param channel The address of the channel
    /// @return claimableAmount The amount that can be claimed by the subscriber
    function getClaimableAmount(address subscriber, address channel) external view returns (uint256 claimableAmount);

    /// @notice Calculates the total claimable amount for a subscriber in multiple channels
    /// @dev Determines the total amount that a subscriber can claim from the specified channels
    /// @param subscriber The address of the subscriber
    /// @param channels The addresses of the channels
    /// @return totalClaimableAmount The total amount that can be claimed by the subscriber
    /// @return claimableChannels The addresses of the channels from which the subscriber can claim
    function getTotalClaimableAmount(address subscriber, address[] calldata channels)
        external
        view
        returns (uint256 totalClaimableAmount, address[] memory claimableChannels);

    /// @notice Calculates the total daily max claimable amount for a subscriber in multiple channels
    /// @dev Determines the total amount that a subscriber can claim from the specified channels
    /// @param subscriber The address of the subscriber
    /// @param channels The addresses of the channels
    /// @return totalDailyMaxClaimableAmount The total amount that can be claimed by the subscriber
    function getTotalDailyMaxClaimableAmount(address subscriber, address[] calldata channels)
        external
        view
        returns (uint256 totalDailyMaxClaimableAmount);
}
