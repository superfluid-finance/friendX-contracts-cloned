// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {
    ISuperfluid, ISuperApp
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

import { Channel, ChannelBase } from "../src/Channel.sol";
import { ChannelFactory } from "../src/ChannelFactory.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { getSubscribeBatchOperation } from "../src/BatchOperationHelpers.sol";
import { upgradeChannel } from "../script/UpgradeChannelBeaconLogic.s.sol";

using SuperTokenV1Library for SuperToken;


contract ChannelUpgradeForkTest is Test {
    address constant DEPLOYER = 0xc33539b3cA1923624762E8a42D699806C865D652;

    ISuperfluid    constant HOST = ISuperfluid(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74);
    SuperToken     constant DEGENX_TOKEN = SuperToken(0x1efF3Dd78F4A14aBfa9Fa66579bD3Ce9E1B30529);
    FanToken       constant ALFA_TOKEN = FanToken(0x905Cf6aDF9510EE12C78dD9c6A5445320db24342);
    ChannelFactory constant CHANNEL_FACTPRY = ChannelFactory(0x30E0b740AcFb45b6eDB9eeD40094134F24d8F159);

    Channel constant WAKE_CHANNEL = Channel(0x35594aCfed507027A32D7D05dC77015703A1bb8C);
    Channel constant TOKI_CHANNEL = Channel(0x61CAD30171db794b5a14E6d6D01E6069d2009A1A);

    address constant ELVIJS_AA = 0xCeDF538EEeEB6Cd2a07668b89FD2B9675cdb52A1;
    address constant TOKI_AA = 0x580c76a847826171B30a54DC862987173Ce0b729;
    address constant HELLWOLF_AA = 0x9E59c6c5590A2a272F6dA2E2a3F59812D35aF771;

    uint256 fork;

    function setUp() public {
        fork = vm.createFork(vm.envString("FOUNDRY_ETH_RPC_URL"));

        testUpgradePermission();

        vm.startPrank(DEPLOYER);
        (Channel oldImpl, Channel newImpl) = upgradeChannel(CHANNEL_FACTPRY);
        vm.stopPrank();

        assertEq(address(oldImpl.HOST()), address(HOST));
        assertEq(address(oldImpl.PROTOCOL_FEE_DESTINATION()), address(DEPLOYER));
        assertEq(address(oldImpl.SUBSCRIPTION_SUPER_TOKEN()), address(DEGENX_TOKEN));
        assertEq(address(oldImpl.FAN()), address(ALFA_TOKEN));

        assertEq(address(newImpl.HOST()), address(oldImpl.HOST()));
        assertEq(address(newImpl.PROTOCOL_FEE_DESTINATION()), address(oldImpl.PROTOCOL_FEE_DESTINATION()));
        assertEq(address(newImpl.SUBSCRIPTION_SUPER_TOKEN()), address(oldImpl.SUBSCRIPTION_SUPER_TOKEN()));
        assertEq(address(newImpl.FAN()), address(oldImpl.FAN()));

        vm.deal(ELVIJS_AA, 69 ether);
        vm.deal(TOKI_AA, 42 ether);
        vm.deal(HELLWOLF_AA, 100 ether);

        assertFalse(HOST.isAppJailed(WAKE_CHANNEL), "wake should be free");
    }

    function testUpgradePermission() public {
        UpgradeableBeacon beacon = CHANNEL_FACTPRY.CHANNEL_BEACON();
        vm.expectRevert("Ownable: caller is not the owner");
        beacon.upgradeTo(address(0x4269));
    }

    function testUnsubSub() external {
        vm.startPrank(ELVIJS_AA);

        assertGt(DEGENX_TOKEN.getFlowRate(ELVIJS_AA, address(WAKE_CHANNEL)), 0, "Elvijs not woke");
        DEGENX_TOKEN.deleteFlow(ELVIJS_AA, address(WAKE_CHANNEL));
        assertFalse(HOST.isAppJailed(WAKE_CHANNEL), "wake not got jailed 1");

        HOST.batchCall(getSubscribeBatchOperation(HOST, DEGENX_TOKEN,
                                                  address(WAKE_CHANNEL), WAKE_CHANNEL.subscriptionFlowRate()));
        assertFalse(HOST.isAppJailed(WAKE_CHANNEL), "wake not got jailed 2");
        vm.stopPrank();
    }

    function testClaimStakeAndUnstake() external {
        address who = ELVIJS_AA;
        vm.startPrank(who);

        uint256 s0 = ALFA_TOKEN.stakedBalanceOf(who, address(WAKE_CHANNEL));

        uint256 b0 = ALFA_TOKEN.balanceOf(who);
        ALFA_TOKEN.claim(address(WAKE_CHANNEL));
        uint256 b1 = ALFA_TOKEN.balanceOf(who);
        assertGt(b1, b0, "no alfa claimed");

        ALFA_TOKEN.stake(address(WAKE_CHANNEL), b1);

        uint256 s1 = ALFA_TOKEN.stakedBalanceOf(who, address(WAKE_CHANNEL));
        assertEq(s1, s0 + b1, "staking balance not matching");
        ALFA_TOKEN.unstake(address(WAKE_CHANNEL), s1);

        vm.expectRevert(IFanToken.FAN_TOKEN_UNSTAKE_COOLDOWN_NOT_OVER.selector);
        ALFA_TOKEN.stake(address(WAKE_CHANNEL), s1);

        vm.stopPrank();
    }

    function testDavidBun() external {
        Channel DA_CHANNEL = Channel(0xe25DEf25177A0b90dAbfd97Ad1a0dAD77e6bED89);

        vm.startPrank(ELVIJS_AA);
        {
            uint256 b0 = ALFA_TOKEN.balanceOf(ELVIJS_AA);
            ALFA_TOKEN.claim(address(WAKE_CHANNEL));
            uint256 b1 = ALFA_TOKEN.balanceOf(ELVIJS_AA);
            assertGt(b1, b0, "no alfa claimed");

            ALFA_TOKEN.stake(address(DA_CHANNEL), b1);
        }
        vm.stopPrank();

        vm.startPrank(TOKI_AA);
        {
            HOST.batchCall(getSubscribeBatchOperation(HOST, DEGENX_TOKEN,
                                                      address(DA_CHANNEL), DA_CHANNEL.subscriptionFlowRate()));
            assertFalse(HOST.isAppJailed(ISuperApp(DA_CHANNEL)), "wake got jailed 2");
        }
        vm.stopPrank();
    }

    function testChannelMigration_r0_r1() external {
        console2.log("=== Migrating Elvij's friend's channel from regime 0 to regime 1");

        Channel C = Channel(0xD16b144F4eAd9b73aEDd58Dd26A0696Dc9433eB6);
        address CO = C.owner();
        address[] memory B = new address[](2);
        B[0] = 0x14F13305e176CE4D76d2EA4F4380E06DD1251Bb4;
        B[1] = 0x2304017aED306818cAB44A6cA81A86Fd38f28343;
        address NB = 0x871bda53E3aa3fE63009A31097161dC3F0174e44; // non migrated staker

        console2.log("Channel %s owner %s channelPool %s", address(C), CO, address(C.channelPool()));
        assertFalse(HOST.isAppJailed(C), "wake should be free");

        console2.log("Testing permission control of governance functions...");
        vm.expectRevert(ChannelBase.ONLY_GOV_ALLOWED.selector);
        C.govMarkRegimeUpgradeStarted();

        vm.expectRevert(ChannelBase.ONLY_GOV_ALLOWED.selector);
        C.govUpgradeStakers(B);
        console2.log("Passed");

        // Now, let's be real

        {
            vm.startPrank(DEPLOYER);

            console2.log("Testing effectiveness of govMarkRegimeUgrade...");
            assertEq(C.stakerRegimeRevisions(C.owner()), 0, "CO rev before migration");
            assertEq(C.stakerRegimeRevisions(DEPLOYER), 0, "DEPLOYER rev before migration");
            assertEq(C.stakerRegimeRevisions(B[0]), 0, "b0 rev before migration");
            assertEq(C.stakerRegimeRevisions(B[1]), 0, "b1 rev before migration");
            C.govUpgradeStakers(B);
            assertEq(C.stakerRegimeRevisions(B[0]), 0, "b0 rev after wrong migration");
            assertEq(C.stakerRegimeRevisions(B[1]), 0, "b1 rev after wrong migration");
            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(DEPLOYER);

            console2.log("Activating migration...");

            console2.log("CO units before migration", C.channelPool().getUnits(C.owner()));
            console2.log("DEPLOYER units before migration", C.channelPool().getUnits(DEPLOYER));
            console2.log("b0 units before migration", C.channelPool().getUnits(B[0]));
            console2.log("b1 units before migration", C.channelPool().getUnits(B[1]));

            assertEq(C.stakerRegimeRevisions(C.owner()), 0, "CO rev before migration");
            assertEq(C.stakerRegimeRevisions(DEPLOYER), 0, "DEPLOYER rev before migration");
            assertEq(C.stakerRegimeRevisions(B[0]), 0, "b0 rev before migration");
            assertEq(C.stakerRegimeRevisions(B[1]), 0, "b1 rev before migration");
            assertEq(C.stakerRegimeRevisions(NB), 0, "nb rev before migration");

            C.govMarkRegimeUpgradeStarted();
            C.govUpgradeStakers(B);
            assertEq(C.stakerRegimeRevisions(C.owner()), 1, "CO rev before migration");
            assertEq(C.stakerRegimeRevisions(DEPLOYER), 1, "DEPLOYER rev before migration");
            assertEq(C.stakerRegimeRevisions(B[0]), 1, "b0 rev after migration");
            assertEq(C.stakerRegimeRevisions(B[1]), 1, "b1 rev after migration");
            assertEq(C.stakerRegimeRevisions(NB), 0, "nb rev after migration");

            console2.log("CO units after migration", C.channelPool().getUnits(C.owner()));
            console2.log("DEPLOYER units after migration", C.channelPool().getUnits(DEPLOYER));
            console2.log("b0 units after migration", C.channelPool().getUnits(B[0]));
            console2.log("b1 units after migration", C.channelPool().getUnits(B[1]));

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(TOKI_AA);

            console2.log("Fresh subscriber Toki...");

            assertEq(DEGENX_TOKEN.getFlowRate(TOKI_AA, address(C)), 0, "Toki subscribed!?");

            HOST.batchCall(getSubscribeBatchOperation(HOST, DEGENX_TOKEN,
                                                      address(C), C.subscriptionFlowRate()));
            assertFalse(HOST.isAppJailed(C), "Channel not got jailed");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(ELVIJS_AA);

            console2.log("Existing subscriber Elvijs...");

            assertGt(DEGENX_TOKEN.getFlowRate(ELVIJS_AA, address(C)), 0, "Elvijs not subscribed!?");
            DEGENX_TOKEN.deleteFlow(ELVIJS_AA, address(C));
            assertFalse(HOST.isAppJailed(C), "wake not got jailed 1");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(B[0]);

            console2.log("Existing migrated staker B0...");

            ALFA_TOKEN.claim(address(C));
            uint256 b0 = ALFA_TOKEN.balanceOf(B[0]);
            console2.log("B0 alfa balance %d", b0);
            assertGt(b0, 0, "B0 should've claimed some alfa");

            uint256 s0 = ALFA_TOKEN.stakedBalanceOf(B[0], address(C));
            console2.log("B0 stake %d units %d", s0, C.channelPool().getUnits(B[0]));

            ALFA_TOKEN.stake(address(C), b0);
            uint256 s1 = ALFA_TOKEN.stakedBalanceOf(B[0], address(C));
            console2.log("B0 stake %d units %d", s1, C.channelPool().getUnits(B[0]));
            assertEq(ALFA_TOKEN.balanceOf(B[0]), 0, "b0 staked all");

            ALFA_TOKEN.unstake(address(C), s1);
            assertEq(ALFA_TOKEN.stakedBalanceOf(B[0], address(C)), 0, "B0 should now have 0 stake");
            assertEq(C.channelPool().getUnits(B[0]), 0, "B0 units should now be 0");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(NB);

            console2.log("Existing non-migrated staker NB...");

            ALFA_TOKEN.claim(address(WAKE_CHANNEL));
            uint256 b0 = ALFA_TOKEN.balanceOf(NB);
            console2.log("NB alfa balance %d", b0);
            assertGt(b0, 0, "NB should've claimed some alfa");

            uint256 s0 = ALFA_TOKEN.stakedBalanceOf(NB, address(C));
            console2.log("NB stake %d units %d", s0, C.channelPool().getUnits(NB));

            assertEq(C.stakerRegimeRevisions(NB), 0, "NB rev before auto-migration");
            ALFA_TOKEN.stake(address(C), b0);
            uint256 s1 = ALFA_TOKEN.stakedBalanceOf(NB, address(C));
            console2.log("NB stake %d units %d", s1, C.channelPool().getUnits(NB));
            assertEq(ALFA_TOKEN.balanceOf(NB), 0, "NB staked all");
            assertEq(C.stakerRegimeRevisions(NB), 1, "NB rev after auto-migration");

            ALFA_TOKEN.unstake(address(C), s1);
            assertEq(ALFA_TOKEN.stakedBalanceOf(NB, address(C)), 0, "NB should now have 0 stake");
            assertEq(C.channelPool().getUnits(NB), 0, "NB units should now be 0");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(CO);

            console2.log("Channel owner plays with himself...");

            ALFA_TOKEN.claim(address(WAKE_CHANNEL));
            uint256 b0 = ALFA_TOKEN.balanceOf(CO);
            console2.log("CO new alfa balance %d", b0);
            assertGt(b0, 0, "CO should've claimed some alfa");

            uint256 s0 = ALFA_TOKEN.stakedBalanceOf(CO, address(C));
            console2.log("CO stake %d units %d", s0, C.channelPool().getUnits(CO));

            assertEq(C.stakerRegimeRevisions(CO), 1, "CO rev before auto-migration");
            ALFA_TOKEN.stake(address(C), b0);
            uint256 s1 = ALFA_TOKEN.stakedBalanceOf(CO, address(C));
            console2.log("CO stake %d units %d", s1, C.channelPool().getUnits(CO));
            assertEq(ALFA_TOKEN.balanceOf(CO), 0, "CO staked all");

            uint256 s2 = ALFA_TOKEN.stakedBalanceOf(CO, address(C));
            ALFA_TOKEN.unstake(address(C), s1);
            console2.log("CO stake %d units %d", s2, C.channelPool().getUnits(CO));
            assertEq(ALFA_TOKEN.stakedBalanceOf(CO, address(C)), 0, "CO should now have 0 stake");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }

        {
            vm.startPrank(HELLWOLF_AA);

            console2.log("Fresh staker hellwolf...");

            assertEq(ALFA_TOKEN.stakedBalanceOf(HELLWOLF_AA, address(C)), 0, "hellwolf should have 0 stake, 1st");
            assertEq(C.channelPool().getUnits(HELLWOLF_AA), 0, "hellwolf units should be 0, 1st");

            uint256 b0 = ALFA_TOKEN.balanceOf(HELLWOLF_AA);
            ALFA_TOKEN.claim(address(TOKI_CHANNEL));
            uint256 b1 = ALFA_TOKEN.balanceOf(HELLWOLF_AA);
            assertGt(b1, b0, "no alfa claimed");
            console2.log("Alfa claimed %d", b1);

            ALFA_TOKEN.stake(address(C), b1);

            uint256 s1 = ALFA_TOKEN.stakedBalanceOf(HELLWOLF_AA, address(C));
            assertEq(s1, b1, "staking balance not matching");
            console2.log("hellwolf new units %d", C.channelPool().getUnits(HELLWOLF_AA));

            ALFA_TOKEN.unstake(address(C), s1);
            assertEq(ALFA_TOKEN.stakedBalanceOf(HELLWOLF_AA, address(C)), 0, "hellwolf should have 0 stake, 2nd");
            assertEq(C.channelPool().getUnits(HELLWOLF_AA), 0, "hellwolf units should be 0, 2nd");

            console2.log(unicode"✅ Passed");

            vm.stopPrank();
        }
    }
}
