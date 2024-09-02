// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Script, console2 } from "forge-std/Script.sol";
import {
    ISuperfluid, ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { ChannelFactory } from "../src/ChannelFactory.sol";
import { Channel } from "../src/Channel.sol";

function deployAll(ISuperfluid host,
                   ISuperToken subscriptionSuperToken,
                   address protocolFeeDest, address initialOwner)
    returns (address fanTokenProxy, address channelLogicAddress, address channelFactoryAddress)
{
    // deploy the fan token logic and proxy contract
    FanToken fanTokenLogicContract = new FanToken();

    // a 2x reward bonus to reward early adopters which goes down to 1x over 1 month
    bytes memory callData =
        abi.encodeWithSelector(FanToken.initialize.selector, initialOwner, 180 days, 30000, 2500, 7500);
    ERC1967Proxy fanTokenProxyContract = new ERC1967Proxy(address(fanTokenLogicContract), callData);

    fanTokenProxy = address(fanTokenProxyContract);
    FanToken fanToken = FanToken(fanTokenProxy);

    // deploy the channel logic contract
    // constructor calls disable initializers so it cannot be initialized arbitrarily
    Channel channelLogic = new Channel(host,
                                       subscriptionSuperToken, fanToken,
                                       protocolFeeDest, 5_00 /* 5% */,
                                       0, type(int96).max /* min/max subscription flow rate */);
    channelLogicAddress = address(channelLogic);

    // deploy the channel factory contract and initialize it so it cannot be initialized arbitrarily
    ChannelFactory channelFactory = new ChannelFactory(host, address(channelLogic));
    channelFactoryAddress = address(channelFactory);

    // transfer ownership to the desired owner from address(this)
    channelFactory.CHANNEL_BEACON().transferOwnership(initialOwner);

    // set the channel factory on the fan token for checks on whether
    // channels calling functions via the token are valid
    fanToken.setChannelFactory(address(channelFactory));

    // transfer ownership back to the desired owner from address(this)
    /* if (initialOwner != owner) { */
    /*     fanToken.setOwner(owner); */
    /* } */
}

// forge script script/Deploy.s.sol:DeployScript --rpc-url $RPC_URL --broadcast --verify -vvvv
contract DeployScript is Script {
    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ISuperfluid host = ISuperfluid(vm.envAddress("HOST_ADDRESS"));

        ISuperToken subscriptionSuperToken = ISuperToken(vm.envAddress("SUBSCRIPTION_SUPER_TOKEN_ADDRESS"));

        address protocolFeeDest = vm.envAddress("PROTOCOL_FEE_DEST");

        address owner = vm.envAddress("OWNER_ADDRESS");

        deployAll(host, subscriptionSuperToken, protocolFeeDest, owner);
    }
}
