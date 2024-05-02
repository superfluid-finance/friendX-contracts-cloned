// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ERC1820RegistryCompiled } from "superfluid-contracts/libs/ERC1820RegistryCompiled.sol";
import { SuperfluidFrameworkDeployer } from "superfluid-contracts/utils/SuperfluidFrameworkDeployer.sol";
import { ISETH } from "superfluid-contracts/interfaces/tokens/ISETH.sol";
import {
    BatchOperation,
    ISuperfluid,
    ISuperfluidPool,
    IGeneralDistributionAgreementV1,
    ISuperApp
} from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { TestToken } from "superfluid-contracts/utils/TestToken.sol";
import { SuperToken } from "superfluid-contracts/superfluid/SuperToken.sol";
import { SuperTokenV1Library } from "superfluid-contracts/apps/SuperTokenV1Library.sol";
import { deployAll } from "../script/Deploy.s.sol";
import { AccountingHelperLibrary } from "../src/libs/AccountingHelperLibrary.sol";
import { Channel, ChannelBase } from "../src/Channel.sol";
import { FanToken } from "../src/FanToken.sol";
import { ChannelFactory, IChannelFactory } from "../src/ChannelFactory.sol";
import { getSubscribeBatchOperation, getUpdateSubscriptionBatchOperation } from "../src/BatchOperationHelpers.sol";

using SuperTokenV1Library for ISETH;
using SuperTokenV1Library for SuperToken;
using SafeCast for uint256;

contract SFTest is Test {
    uint256 public constant INITIAL_BALANCE = 10000 ether;

    SuperfluidFrameworkDeployer.Framework internal _sf;
    SuperfluidFrameworkDeployer internal _deployer;

    FanToken public fanToken;
    Channel public channelLogic;
    ChannelFactory public channelFactory;

    address public constant ADMIN = address(0x420);
    address public constant ALICE = address(0x1);
    address public constant BOB = address(0x2);
    address public constant CAROL = address(0x3);
    address public constant PROTOCOL_FEE_DESTINATION = address(0x42069);
    address[] internal TEST_ACCOUNTS = [ADMIN, ALICE, BOB, CAROL];

    ISETH internal _ethX;
    TestToken internal _underlyingSubscriptionToken;
    SuperToken internal _subscriptionSuperToken;

    function setUp() public virtual {
        // Superfluid Protocol Deployment Start
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        _deployer = new SuperfluidFrameworkDeployer();
        _deployer.deployTestFramework();
        _sf = _deployer.getFramework();

        _ethX = _deployer.deployNativeAssetSuperToken("Super ETH", "ETHx");

        (_underlyingSubscriptionToken, _subscriptionSuperToken) =
            _deployer.deployWrapperSuperToken("Super USDC", "USDCx", 6, type(uint256).max, address(0));

        // Superfluid Protocol Deployment End

        // Mint tokens for test accounts
        for (uint256 i; i < TEST_ACCOUNTS.length; ++i) {
            vm.startPrank(TEST_ACCOUNTS[i]);
            vm.deal(TEST_ACCOUNTS[i], INITIAL_BALANCE);
            _ethX.upgradeByETH{ value: INITIAL_BALANCE / 2 }();

            _underlyingSubscriptionToken.mint(TEST_ACCOUNTS[i], INITIAL_BALANCE);
            _underlyingSubscriptionToken.approve(address(_subscriptionSuperToken), INITIAL_BALANCE / 2);
            _subscriptionSuperToken.upgrade(INITIAL_BALANCE / 2);
            vm.stopPrank();
        }

        // OnlyFrens Deployment Start
        vm.startPrank(ADMIN);
        (address fanTokenProxy, address channel, address channelFactoryProxy) =
            deployAll(_sf.host, _subscriptionSuperToken, PROTOCOL_FEE_DESTINATION, ADMIN);
        fanToken = FanToken(fanTokenProxy);
        channelLogic = Channel(channel);
        channelFactory = ChannelFactory(channelFactoryProxy);
        vm.stopPrank();

        // OnlyFrens Deployment End

        // Good Ol' SuperTokenV1Library cache warm up
        _subscriptionSuperToken.setMaxFlowPermissions(address(channelFactory));
        _subscriptionSuperToken.setMaxFlowPermissions(address(channelFactory));
    }

    //// CHANNEL FACTORY ////

    function _helperCreateChannelContract(address creator, int96 flowRate, uint256 creatorFeePct)
        internal
        returns (address channelInstance)
    {
        vm.assume(flowRate > 0);
        creatorFeePct = channelLogic.ONE_HUNDRED_PERCENT() / 4;

        vm.startPrank(creator);
        channelInstance = channelFactory.createChannelContract(flowRate, creatorFeePct);
        vm.stopPrank();

        _assertChannelCreation(channelInstance, creator, flowRate, creatorFeePct);
    }

    function _helperCreateChannelContractOnBehalf(
        address creator,
        address channelOwner,
        int96 flowRate,
        uint256 creatorFeePct
    ) internal returns (address channelInstance) {
        vm.assume(flowRate > 0);
        creatorFeePct = channelLogic.ONE_HUNDRED_PERCENT() / 4;

        vm.startPrank(creator);
        channelInstance = channelFactory.createChannelContract(channelOwner, flowRate, creatorFeePct);
        vm.stopPrank();

        _assertChannelCreation(channelInstance, channelOwner, flowRate, creatorFeePct);
    }

    function _assertChannelCreation(
        address channelInstance,
        address channelOwner,
        int96 flowRate,
        uint256 creatorFeePct
    ) internal {
        address precomputedAddress = channelFactory.getChannelAddress(channelOwner);

        assertEq(
            Channel(channelInstance).subscriptionFlowRate(),
            flowRate,
            "testDeployChannelContract: channel contract flowRate incorrectly set"
        );

        assertEq(
            Channel(channelInstance).owner(),
            channelOwner,
            "testDeployChannelContract: channel contract owner incorrectly set"
        );

        assertEq(
            Channel(channelInstance).creatorFeePercentage(),
            creatorFeePct,
            "testDeployChannelContract: channel contract creatorFeePercentage incorrectly set"
        );

        assertEq(
            channelInstance, precomputedAddress, "testDeployChannelContract: channel contract incorrectly deployed"
        );
    }

    function _helperCreateChannelContractAndSubscribeToIt(
        address creator,
        address subscriber,
        int96 flowRate,
        uint256 creatorFeePct
    ) internal returns (address channelInstance) {
        flowRate = int96(bound(flowRate, int96(0.05 ether) / int96(30 days), int96(1e15)));
        channelInstance = _helperCreateChannelContract(creator, int96(0.05 ether) / int96(30 days), creatorFeePct);

        ChannelBase channel = ChannelBase(channelInstance);

        int96 senderToChannelFlowRateBefore = _subscriptionSuperToken.getFlowRate(subscriber, channelInstance);

        int96 flowRateDelta = flowRate - senderToChannelFlowRateBefore;

        int96 totalInflowRateBefore = channel.totalInflowRate();
        {
            ISuperfluid.Operation[] memory ops =
                getSubscribeBatchOperation(_sf, _subscriptionSuperToken, subscriber, channelInstance, flowRate);

            vm.startPrank(subscriber);
            _sf.host.batchCall(ops);
            vm.stopPrank();
        }
        (uint256 liquidationPeriod,) = _sf.governance.getPPPConfig(_sf.host, _subscriptionSuperToken);

        int96 senderToAppFlowRate = _subscriptionSuperToken.getFlowRate(subscriber, channelInstance);
        uint256 actualDepositAmount = liquidationPeriod * uint256(uint96(senderToAppFlowRate));
        assertEq(
            flowRate, senderToAppFlowRate, "_helperCreateChannelContractAndSubscribeToIt: flow rate not set correctly"
        );

        assertEq(
            totalInflowRateBefore + flowRateDelta,
            channel.totalInflowRate(),
            "_helperCreateChannelContractAndSubscribeToIt: total inflow rate not set correctly"
        );

        assertEq(
            _subscriptionSuperToken.balanceOf(channelInstance),
            actualDepositAmount,
            "_helperCreateChannelContractAndSubscribeToIt: channel contract balance should hold deposit"
        );

        assertEq(
            _sf.gda.isMemberConnected(channel.channelPool(), subscriber),
            true,
            "_helperCreateChannelContractAndSubscribeToIt: subscriber should be connected to pool"
        );
        _assertAppNotJailed(address(channel));
    }

    function _helperUpdateSubscriptionFlowRate(address subscriber, address channelInstance, int96 updatedFlowRate)
        internal
    {
        {
            ISuperfluid.Operation[] memory ops =
                getUpdateSubscriptionBatchOperation(_sf, _subscriptionSuperToken, subscriber, channelInstance, updatedFlowRate);

            vm.startPrank(subscriber);
            _sf.host.batchCall(ops);
            vm.stopPrank();
        }
    }

    //// CHANNEL ////
    function _helperHandleStake(ChannelBase channel, address subscriber, uint128 stakeDelta) public {
        stakeDelta = bound(stakeDelta, 0, 1_000 ether).toUint128();

        ISuperfluidPool channelETHxPool = channel.channelPool();

        // @note - this is not ideal, we shouldn't make the user wait 4 hours until they can stake their tokens...
        // UNLESS, we force them to come back tomorrow to start the habit
        // warp until the pool has enough deposit to start the stream

        uint128 protocolUnitsBefore = channelETHxPool.getUnits(channel.PROTOCOL_FEE_DESTINATION());
        uint128 creatorUnitsBefore = channelETHxPool.getUnits(channel.owner());
        uint128 subscriberUnitsBefore = channelETHxPool.getUnits(subscriber);

        vm.startPrank(address(fanToken));
        channel.handleStake(subscriber, stakeDelta);
        vm.stopPrank();

        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta) =
        AccountingHelperLibrary.getPoolUnitDeltaAmounts(
            stakeDelta, channel.ONE_HUNDRED_PERCENT(), channel.PROTOCOL_FEE_AMOUNT(), channel.creatorFeePercentage()
        );

        assertEq(
            protocolUnitsBefore + protocolFeeUnitsDelta,
            channelETHxPool.getUnits(channel.PROTOCOL_FEE_DESTINATION()),
            "_helperHandleStake: protocol units not set correctly"
        );
        assertEq(
            creatorUnitsBefore + creatorUnitsDelta,
            channelETHxPool.getUnits(channel.owner()),
            "_helperHandleStake: creator units not set correctly"
        );
        assertEq(
            channel.getSubscriberCashbackPercentage() == 0 ? 0 : subscriberUnitsBefore + subscriberUnitsDelta,
            channelETHxPool.getUnits(subscriber),
            "_helperHandleStake: subscriber units not set correctly"
        );
        _assertAppNotJailed(address(channel));
    }

    function _helperHandleUnstake(ChannelBase channel, address subscriber, uint128 unstakeDelta) public {
        unstakeDelta = bound(unstakeDelta, 0, 1_000 ether).toUint128();

        ISuperfluidPool channelETHxPool = channel.channelPool();

        // warp until the pool has enough deposit to start the stream
        (uint256 liquidationPeriod,) = _sf.governance.getPPPConfig(_sf.host, _subscriptionSuperToken);
        vm.warp(block.timestamp + liquidationPeriod);

        uint128 protocolUnitsBefore = channelETHxPool.getUnits(channel.PROTOCOL_FEE_DESTINATION());
        uint128 creatorUnitsBefore = channelETHxPool.getUnits(channel.owner());
        uint128 subscriberUnitsBefore = channelETHxPool.getUnits(subscriber);

        vm.startPrank(address(fanToken));
        channel.handleUnstake(subscriber, unstakeDelta);
        vm.stopPrank();

        (uint128 protocolFeeUnitsDelta, uint128 creatorUnitsDelta, uint128 subscriberUnitsDelta) =
        AccountingHelperLibrary.getPoolUnitDeltaAmounts(
            unstakeDelta, channel.ONE_HUNDRED_PERCENT(), channel.PROTOCOL_FEE_AMOUNT(), channel.creatorFeePercentage()
        );

        assertEq(
            protocolUnitsBefore - protocolFeeUnitsDelta,
            channelETHxPool.getUnits(channel.PROTOCOL_FEE_DESTINATION()),
            "_helperHandleUnstake: protocol units not set correctly"
        );
        assertEq(
            creatorUnitsBefore - creatorUnitsDelta,
            channelETHxPool.getUnits(channel.owner()),
            "_helperHandleUnstake: creator units not set correctly"
        );
        assertEq(
            channel.getSubscriberCashbackPercentage() == 0 ? 0 : subscriberUnitsBefore - subscriberUnitsDelta,
            channelETHxPool.getUnits(subscriber),
            "_helperHandleUnstake: subscriber units not set correctly"
        );
        _assertAppNotJailed(address(channel));
    }

    //// FAN TOKEN ////

    function _helperStake(address caller, address channel, uint256 amount) internal {
        (
            uint256 fanBalanceBefore,
            uint256 stakedFanBalanceBefore,
            uint256 totalStakedBefore,
            uint256 channelStakedBalanceBefore
        ) = _helperGetBalancesBefore(caller, channel);

        vm.startPrank(caller);
        fanToken.stake(channel, amount);
        vm.stopPrank();

        assertEq(
            fanBalanceBefore - amount, fanToken.balanceOf(caller), "_helperStake: fan balance should decrease by amount"
        );
        assertEq(
            stakedFanBalanceBefore + amount,
            fanToken.stakedBalanceOf(caller, channel),
            "_helperStake: staked fan balance should increase by amount"
        );
        assertEq(
            totalStakedBefore + amount, fanToken.totalStaked(), "_helperStake: total staked should increase by amount"
        );
        assertEq(
            channelStakedBalanceBefore + amount,
            fanToken.channelStakedBalanceOf(channel),
            "_helperStake: channel staked balance should increase by amount"
        );
        _assertAppNotJailed(channel);
    }

    function _helperUnstake(address caller, address channel, uint256 amount) internal {
        (
            uint256 fanBalanceBefore,
            uint256 stakedFanBalanceBefore,
            uint256 totalStakedBefore,
            uint256 channelStakedBalanceBefore
        ) = _helperGetBalancesBefore(caller, channel);

        vm.startPrank(caller);
        fanToken.unstake(channel, amount);
        vm.stopPrank();

        assertEq(
            fanBalanceBefore + amount,
            fanToken.balanceOf(caller),
            "_helperUnstake: fan balance should increase by amount"
        );
        assertEq(
            stakedFanBalanceBefore - amount,
            fanToken.stakedBalanceOf(caller, channel),
            "_helperUnstake: staked fan balance should decrease by amount"
        );
        assertEq(
            totalStakedBefore - amount, fanToken.totalStaked(), "_helperUnstake: total staked should decrease by amount"
        );
        assertEq(
            channelStakedBalanceBefore - amount,
            fanToken.channelStakedBalanceOf(channel),
            "_helperUnstake: channel staked balance should decrease by amount"
        );
        assertEq(
            fanToken.getSubscriberData(caller).lastUnstakedTime,
            block.timestamp,
            "_helperUnstake: lastUnstakedTime should be set to current block timestamp"
        );
        _assertAppNotJailed(channel);
    }

    function _helperClaim(address caller, address channel) internal {
        (
            uint256 fanBalanceBefore,
            uint256 stakedFanBalanceBefore,
            uint256 totalStakedBefore,
            uint256 channelStakedBalanceBefore
        ) = _helperGetBalancesBefore(caller, channel);

        uint256 claimableAmount = fanToken.getClaimableAmount(caller, channel);

        vm.startPrank(caller);
        fanToken.claim(channel);
        vm.stopPrank();

        assertEq(
            fanBalanceBefore + claimableAmount,
            fanToken.balanceOf(caller),
            "_helperClaim: fan balance should increase by claimable amount"
        );
        assertEq(fanToken.getClaimableAmount(caller, channel), 0, "_helperClaim: claimable amount should be 0");
        assertEq(
            stakedFanBalanceBefore,
            fanToken.stakedBalanceOf(caller, channel),
            "_helperClaim: staked fan balance should remain the same"
        );
        assertEq(totalStakedBefore, fanToken.totalStaked(), "_helperClaim: total staked should remain the same");
        assertEq(
            channelStakedBalanceBefore,
            fanToken.channelStakedBalanceOf(channel),
            "_helperClaim: channel staked balance should remain the same"
        );
        assertEq(
            fanToken.getSubscriberCreatorChannelData(caller, channel).lastClaimedTime,
            block.timestamp,
            "_helperClaim: lastClaimedTime should be set to current block timestamp"
        );
    }

    function _helperCompound(address caller, address channel) internal {
        (
            uint256 fanBalanceBefore,
            uint256 stakedFanBalanceBefore,
            uint256 totalStakedBefore,
            uint256 channelStakedBalanceBefore
        ) = _helperGetBalancesBefore(caller, channel);

        uint256 claimableAmount = fanToken.getClaimableAmount(caller, channel);

        vm.startPrank(caller);
        fanToken.compound(channel);
        vm.stopPrank();

        assertEq(fanBalanceBefore, fanToken.balanceOf(caller), "_helperCompound: fan balance should remain the same");
        assertEq(fanToken.getClaimableAmount(caller, channel), 0, "_helperCompound: claimable amount should be 0");
        assertEq(
            stakedFanBalanceBefore + claimableAmount,
            fanToken.stakedBalanceOf(caller, channel),
            "_helperCompound: staked fan balance should increase by claimable amount"
        );
        assertEq(
            totalStakedBefore + claimableAmount,
            fanToken.totalStaked(),
            "_helperCompound: total staked should increase by claimable amount"
        );
        assertEq(
            channelStakedBalanceBefore + claimableAmount,
            fanToken.channelStakedBalanceOf(channel),
            "_helperCompound: channel staked balance should increase by claimable amount"
        );
        assertEq(
            fanToken.getSubscriberCreatorChannelData(caller, channel).lastClaimedTime,
            block.timestamp,
            "_helperCompound: lastClaimedTime should be set to current block timestamp"
        );
    }

    function _helperGetBalancesBefore(address caller, address channel)
        internal
        view
        returns (
            uint256 fanBalanceBefore,
            uint256 stakedFanBalanceBefore,
            uint256 totalStakedBefore,
            uint256 channelStakedBalanceBefore
        )
    {
        fanBalanceBefore = fanToken.balanceOf(caller);
        stakedFanBalanceBefore = fanToken.stakedBalanceOf(caller, channel);
        totalStakedBefore = fanToken.totalStaked();
        channelStakedBalanceBefore = fanToken.channelStakedBalanceOf(channel);
    }

    function _helperWarpToFullDeposit() internal {
        (uint256 liquidationPeriod,) = _sf.governance.getPPPConfig(_sf.host, _subscriptionSuperToken);
        vm.warp(block.timestamp + liquidationPeriod);
    }

    function _assertAppNotJailed(address app) internal {
        assertEq(_sf.host.isAppJailed(ISuperApp(app)), false, "_assertAppNotJailed: app should not be jailed");
    }
}
