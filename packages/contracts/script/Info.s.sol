// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "forge-std/console.sol";

import { Script, console2 } from "forge-std/Script.sol";
import { ISETH, ISuperfluid, ISuperfluidPool } from "superfluid-contracts/interfaces/superfluid/ISuperfluid.sol";
import { FanToken, IFanToken } from "../src/FanToken.sol";
import { ChannelFactory } from "../src/ChannelFactory.sol";
import { Channel } from "../src/Channel.sol";

// forge script script/Info.s.sol:InfoScript --rpc-url $RPC_URL -vvvv
contract InfoScript is Script {
    function setUp() public { }

    function run() public {
        uint128 protocolUnits = ISuperfluidPool(0x0D8FCF34C1DFA8C25db95818B5e539A956a9dEda).getUnits(
            0xF72c73981550D5120537e8613e3A9BE4B6F5482E
        );
        uint128 creatorUnits = ISuperfluidPool(0x0D8FCF34C1DFA8C25db95818B5e539A956a9dEda).getUnits(
            0xca0564d840CECF4a6BaF8bA1f88A89fad13069Be
        );
        uint128 memberUnits = ISuperfluidPool(0x0D8FCF34C1DFA8C25db95818B5e539A956a9dEda).getUnits(
            0xca0564d840CECF4a6BaF8bA1f88A89fad13069Be
        );
        int96 totalFlowRate = ISuperfluidPool(0x0D8FCF34C1DFA8C25db95818B5e539A956a9dEda).getTotalFlowRate();
        console.log("protocolUnits", protocolUnits);
        console.log("creatorUnits", creatorUnits);
        console.log("memberUnits", memberUnits);
        console.logInt(totalFlowRate);
    }
}
