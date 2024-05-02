// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import {
    BatchOperation,
    ISuperfluid,
    ISuperToken,
    ISuperfluidPool,
    IGeneralDistributionAgreementV1,
    ISuperApp
} from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { AccountingHelperLibrary } from "../libs/AccountingHelperLibrary.sol";
import {
    HotFuzzBase,
    SuperfluidFrameworkDeployer,
    SuperfluidTester,
    IERC20
} from "@superfluid-finance/hot-fuzz/contracts/HotFuzzBase.sol";
import { Channel, ChannelBase } from "../Channel.sol";
import { ChannelFactory } from "../ChannelFactory.sol";
import { FanToken } from "../FanToken.sol";
import { SubscriberCreatorChannelData, SubscriberData } from "../interfaces/IFanToken.sol";
import { deployAll } from "../../script/Deploy.s.sol";
import { getSubscribeBatchOperation, getUpdateSubscriptionBatchOperation } from "../BatchOperationHelpers.sol";

contract FriendXTester is SuperfluidTester {
    using SuperTokenV1Library for ISuperToken;

    bool public hasChannel;
    mapping(Channel channel => bool) public subscribed;

    constructor(SuperfluidFrameworkDeployer.Framework memory sf_, IERC20 token_, ISuperToken superToken_)
        SuperfluidTester(sf_, token_, superToken_)
    { }

    function createChannel(ChannelFactory cf, int96 subscriptionFlowRate, uint256 creatorFeePct)
        external
        returns (Channel channel)
    {
        channel = Channel(cf.createChannelContract(subscriptionFlowRate, creatorFeePct));
        hasChannel = true;
    }

    function subscribeChannel(Channel channel, int96 subscriptionFlowRate) external returns (bool) {
        ISuperfluid.Operation[] memory ops = getSubscribeBatchOperation(
            sf, channel.SUBSCRIPTION_SUPER_TOKEN(), address(this), address(channel), subscriptionFlowRate
        );
        sf.host.batchCall(ops); // Bad host: not returning bool...
        subscribed[channel] = true;
        return true;
    }

    function updateSubscription(Channel channel, int96 updatedSubscriptionFlowRate) external returns (bool) {
        ISuperfluid.Operation[] memory ops = getUpdateSubscriptionBatchOperation(
            sf, channel.SUBSCRIPTION_SUPER_TOKEN(), address(this), address(channel), updatedSubscriptionFlowRate
        );
        sf.host.batchCall(ops);
        return true;
    }

    function unsubscribeChannel(Channel channel) external returns (bool) {
        assert(channel.SUBSCRIPTION_SUPER_TOKEN().deleteFlow(address(this), address(channel)));
        subscribed[channel] = false;
        return true;
    }

    function claimRewards(FanToken rewardToken, address channel) external returns (bool) {
        rewardToken.claim(channel);
        return true;
    }

    function claimAllRewards(FanToken rewardToken, address[] calldata channels) external returns (bool) {
        rewardToken.claimAll(channels);
        return true;
    }

    function stakeRewards(FanToken rewardToken, address channel, uint256 amount) external returns (bool) {
        rewardToken.stake(channel, amount);
        return true;
    }

    function unstakeRewards(FanToken rewardToken, address channel, uint256 amount) external returns (bool) {
        rewardToken.unstake(channel, amount);
        return true;
    }

    function compound(FanToken rewardToken, address channel) external returns (bool) {
        rewardToken.compound(channel);
        return true;
    }

    function compoundAll(FanToken rewardToken, address[] calldata channels) external returns (bool) {
        rewardToken.compoundAll(channels);
        return true;
    }
}

contract FullHotFuzz is HotFuzzBase {
    using SuperTokenV1Library for ISuperToken;

    uint256 private constant _N_TESTERS = 5;
    address private constant _FEE_DEST = address(0xc02dab61f2194e38aef98bba7f35e82c);
    uint256 public constant INITIAL_ETHX_BALANCE_PER_TESTER = 100 ether;

    ISuperToken private immutable _subscriptionSuperToken;
    FanToken private immutable _fanToken;
    ChannelFactory private immutable _channelFactory;

    Channel[] private _channelList;

    bool private _failureExpected;
    bool private _failureSkipped;
    bool private _unexpectedFailureCaptured;

    constructor() payable HotFuzzBase(_N_TESTERS) {
        // create ETHx
        _subscriptionSuperToken = _sfDeployer.deployNativeAssetSuperToken("ETHx", "ETHx");
        (address fanTokenProxy,, address channelFactoryAddress) = deployAll(sf.host, _subscriptionSuperToken, _FEE_DEST, address(this));
        _fanToken = FanToken(fanTokenProxy);
        _channelFactory = ChannelFactory(channelFactoryAddress);

        assert(address(this).balance > 0);
        _initTesters();
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Actions
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function createNewChannel(uint8 a, uint32 b) external {
        (FriendXTester tester) = FriendXTester(address(_getOneTester(a)));
        int96 subscriptionFlowRate = int96(int256(uint256(b + 1)));
        uint256 creatorFeePct = 2500;

        bool hasChannel = tester.hasChannel();
        try tester.createChannel(_channelFactory, subscriptionFlowRate, creatorFeePct) returns (Channel channel) {
            if (hasChannel) {
                // should not be able to create channel twice
                _unexpectedFailureCaptured = true;
            } else {
                _channelList.push(channel);
            }
        } catch {
            // all parameters are tuned, should always be able to create channel
            if (!hasChannel) {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    function subscribeChannelWithRequiredFlowRate(uint8 a, uint256 b, int32 flowRate) external {
        // @note arbitrarily using int32 to not revert due to too large flow rate
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        int96 subscriptionFlowRate = channel.subscriptionFlowRate();

        bool hadSubscribed = tester.subscribed(channel);
        if (flowRate >= subscriptionFlowRate) {
            try tester.subscribeChannel(channel, subscriptionFlowRate) {
                if (hadSubscribed) {
                    // double subscription bad
                    _unexpectedFailureCaptured = true;
                }
            } catch {
                if (!hadSubscribed) {
                    // must be able to subscribe
                    _unexpectedFailureCaptured = true;
                }
            }
        }
    }

    function subscribeChannelWithInsufficientFlowRate(uint8 a, uint256 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        _failureExpected = true;
        // NOTE: this assume subscriptionFlowRate() > 0, see createNewChannel
        assert(tester.subscribeChannel(channel, channel.subscriptionFlowRate() - 1));
        _failureSkipped = true;
    }

    function updateSubscription(uint8 a, uint256 b, int32 flowRate) external {
        // @note arbitrarily using int32 to not revert due to too large flow rate
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        int96 subscriptionFlowRate = channel.subscriptionFlowRate();

        bool hadSubscribed = tester.subscribed(channel);
        if (flowRate >= subscriptionFlowRate && hadSubscribed) {
            try tester.updateSubscription(channel, flowRate) { }
            catch {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    function unsubscribeChannel(uint8 a, uint256 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        if (_subscriptionSuperToken.getFlowRate(address(tester), address(channel)) > 0) {
            try tester.unsubscribeChannel(channel) { }
            catch {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    function claimTokens(uint8 a, uint8 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        try tester.claimRewards(_fanToken, address(channel)) { }
        catch {
            _unexpectedFailureCaptured = true;
        }
    }

    function claimAllTokens(uint8 a, uint8 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        address[] memory channels = _channelListToAddressList(_channelList);

        try tester.claimAllRewards(_fanToken, channels) { }
        catch {
            _unexpectedFailureCaptured = true;
        }
    }

    function stakeTokens(uint8 a, uint8 b, uint256 amount) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        uint256 rewardTokenBalance = _fanToken.balanceOf(address(tester));
        bool unstakeCooldownOver = _isUnstakeCooldownOver(_fanToken, address(tester));

        (,, uint128 subscriberUnitsDelta) = AccountingHelperLibrary.getPoolUnitDeltaAmounts(
            amount, channel.ONE_HUNDRED_PERCENT(), channel.PROTOCOL_FEE_AMOUNT(), channel.creatorFeePercentage()
        );

        if (rewardTokenBalance >= amount && amount > 0 && unstakeCooldownOver && subscriberUnitsDelta > 0) {
            try tester.stakeRewards(_fanToken, address(channel), amount) { }
            catch {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    function unstakeTokens(uint8 a, uint8 b, uint256 amount) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        SubscriberCreatorChannelData memory data =
            _fanToken.getSubscriberCreatorChannelData(address(tester), address(channel));
        bool unstakeCooldownOver = _isUnstakeCooldownOver(_fanToken, address(tester));

        if (data.stakedBalance >= amount && unstakeCooldownOver) {
            try tester.unstakeRewards(_fanToken, address(channel), amount) { }
            catch {
                if (amount > 10000) {
                    _unexpectedFailureCaptured = true;
                }
            }
        }
    }

    function compoundTokens(uint8 a, uint8 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        Channel channel = _channelList[b % _channelList.length];

        bool unstakeCooldownOver = _isUnstakeCooldownOver(_fanToken, address(tester));

        uint256 claimableAmount = _fanToken.getClaimableAmount(address(tester), address(channel));

        if (unstakeCooldownOver && claimableAmount > 0.001 ether) {
            try tester.compound(_fanToken, address(channel)) { }
            catch {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    function compoundAllTokens(uint8 a, uint8 b) external {
        FriendXTester tester = FriendXTester(address(_getOneTester(a)));
        address[] memory channels = _channelListToAddressList(_channelList);

        bool unstakeCooldownOver = _isUnstakeCooldownOver(_fanToken, address(tester));

        address[] memory channelAddresses = _channelListToAddressList(_channelList);
        (uint256 claimableAmount,) = _fanToken.getTotalClaimableAmount(address(tester), channelAddresses);

        if (unstakeCooldownOver && claimableAmount > 0.001 ether) {
            try tester.compoundAll(_fanToken, channels) { }
            catch {
                _unexpectedFailureCaptured = true;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Invariant
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function echidna_check_test_expectations() external view returns (bool) {
        assert(!_unexpectedFailureCaptured);
        assert(!_failureExpected || (_failureExpected && !_failureSkipped));
        return true;
    }

    function echidna_no_channels_jailed() external view returns (bool) {
        for (uint256 i = 0; i < _channelList.length; i++) {
            (bool isSuperApp, bool isJailed,) = sf.host.getAppManifest(ISuperApp(address(_channelList[i]))); // should not revert
            assert(isSuperApp && isJailed == false);
        }
        return true;
    }

    // function echidna_flow_rate_invariant() external view returns (bool) {
    //     uint256 channelInflowRates;
    //     uint256 totalSubscriptionFlowRatePrice;

    //     for (uint256 i = 0; i < _channelList.length; i++) {
    //         channelInflowRates += uint96(_channelList[i].totalInflowRate());
    //         totalSubscriptionFlowRatePrice += uint96(_channelList[i].subscriptionFlowRate());
    //     }
    //     assert(channelInflowRates >= totalSubscriptionFlowRatePrice);
    //     return true;
    // }

    // function echidna_total_flow_rate_invariant() external view returns (bool) {
    //     uint256 totalInflowRate = uint256(_fanToken.totalSubscriptionInflowRate());
    //     uint256 channelInflowRates;

    //     for (uint256 i = 0; i < _channelList.length; i++) {
    //         Channel channel = _channelList[i];
    //         channelInflowRates += uint96(channel.totalInflowRate());
    //     }
    //     assert(channelInflowRates == totalInflowRate);
    //     return true;
    // }

    // function echidna_deposit_greater_than_gda_flow_invariant() external view returns (bool) {
    //     uint256 userDeposits;
    //     uint256 totalChannelGDAFlowRate;
    //     (uint256 liquidationPeriod,) = sf.governance.getPPPConfig(sf.host, _subscriptionSuperToken);

    //     for (uint256 i; i < _channelList.length; i++) {
    //         Channel channel = _channelList[i];
    //         totalChannelGDAFlowRate += uint96(channel.channelPool().getTotalFlowRate());

    //         for (uint256 j; j < testers.length; j++) {
    //             userDeposits += channel.userDeposits(address(testers[j]));
    //         }
    //     }

    //     assert(userDeposits >= totalChannelGDAFlowRate * liquidationPeriod);
    //     return true;
    // }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _createTester() internal override returns (SuperfluidTester tester) {
        _subscriptionSuperToken.upgrade(INITIAL_ETHX_BALANCE_PER_TESTER);
        tester = new FriendXTester(sf, token, superToken);
        _subscriptionSuperToken.transfer(address(tester), INITIAL_ETHX_BALANCE_PER_TESTER);
    }

    function _channelListToAddressList(Channel[] memory channels) internal pure returns (address[] memory) {
        address[] memory addresses = new address[](channels.length);
        for (uint256 i = 0; i < channels.length; i++) {
            addresses[i] = address(channels[i]);
        }
        return addresses;
    }

    function _isUnstakeCooldownOver(FanToken rewardToken, address subscriber) internal view returns (bool) {
        SubscriberData memory data = rewardToken.getSubscriberData(subscriber);
        return block.timestamp - data.lastUnstakedTime > rewardToken.UNSTAKE_COOLDOWN_PERIOD();
    }
}
