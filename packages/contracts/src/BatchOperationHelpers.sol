// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import {
    BatchOperation,
    ISuperfluid,
    ISuperToken,
    ISuperfluidPool,
    IConstantFlowAgreementV1,
    IGeneralDistributionAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {
    SuperfluidGovernanceBase
} from "@superfluid-finance/ethereum-contracts/contracts/gov/SuperfluidGovernanceBase.sol";

import { ChannelBase } from "./Channel.sol";

import {
    SuperfluidFrameworkDeployer
} from "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.sol";

function getSubscribeBatchOperation(
    ISuperfluid host,
    ISuperToken ethX,
    address channelInstance,
    int96 flowRate
) view returns (ISuperfluid.Operation[] memory ops) {
    SuperfluidGovernanceBase gov = SuperfluidGovernanceBase(address(host.getGovernance()));
    IConstantFlowAgreementV1 cfa = IConstantFlowAgreementV1
        (address(host.getAgreementClass(keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1"))));
    IGeneralDistributionAgreementV1 gda = IGeneralDistributionAgreementV1
        (address(host.getAgreementClass(keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1"))));

    (uint256 liquidationPeriod,) = gov.getPPPConfig(host, ethX);
    uint256 depositAmount = liquidationPeriod * uint256(uint96(flowRate));

    ISuperfluidPool channelPool = ChannelBase(channelInstance).channelPool();

    ops = new ISuperfluid.Operation[](4);
    {
        bytes memory approveArgs = abi.encode(channelInstance, depositAmount);

        bytes memory depositCallAppActionCallData =
            abi.encodeCall(ChannelBase.depositBuffer, (depositAmount, new bytes(0)));

        bytes memory createFlowCallAgreemeentCallData =
            abi.encodeCall(cfa.createFlow, (ethX, channelInstance, flowRate, new bytes(0)));

        bytes memory connectPoolCallAgreementCallData =
            abi.encodeCall(IGeneralDistributionAgreementV1.connectPool, (channelPool, new bytes(0)));

        ops[0] = ISuperfluid.Operation(BatchOperation.OPERATION_TYPE_ERC20_APPROVE, address(ethX), approveArgs);

        ops[1] = ISuperfluid.Operation(
            BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_APP_ACTION, channelInstance, depositCallAppActionCallData
        );

        ops[2] = ISuperfluid.Operation(
            BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            address(cfa),
            abi.encode(createFlowCallAgreemeentCallData, new bytes(0))
        );

        ops[3] = ISuperfluid.Operation(
            BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            address(gda),
            abi.encode(connectPoolCallAgreementCallData, new bytes(0))
        );
    }
}

function getUpdateSubscriptionBatchOperation(
    ISuperfluid host,
    ISuperToken ethX,
    address subscriber,
    address channelInstance,
    int96 flowRate
) view returns (ISuperfluid.Operation[] memory ops) {
    SuperfluidGovernanceBase gov = SuperfluidGovernanceBase(address(host.getGovernance()));
    IConstantFlowAgreementV1 cfa = IConstantFlowAgreementV1
        (address(host.getAgreementClass(keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1"))));

    (uint256 liquidationPeriod,) = gov.getPPPConfig(host, ethX);
    uint256 userDeposit = ChannelBase(channelInstance).userDeposits(subscriber);
    uint256 depositAmount = liquidationPeriod * uint256(uint96(flowRate));
    uint256 depositDelta = userDeposit > depositAmount ? 0 : depositAmount - userDeposit;

    // if depositDelta is less than 0 (decreasing flow rate), we don't need to approve
    // or deposit more tokens, we can simply lower the flow rate
    ops = new ISuperfluid.Operation[](depositDelta > 0 ? 3 : 1);
    {
        bytes memory approveArgs = abi.encode(channelInstance, depositDelta);

        bytes memory updateFlowCallAgreemeentCallData =
            abi.encodeCall(cfa.updateFlow, (ethX, channelInstance, flowRate, new bytes(0)));

        if (depositDelta > 0) {
            ops[0] = ISuperfluid.Operation(BatchOperation.OPERATION_TYPE_ERC20_APPROVE, address(ethX), approveArgs);

            ops[1] = ISuperfluid.Operation(
                BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_APP_ACTION,
                channelInstance,
                abi.encodeCall(ChannelBase.depositBuffer, (depositDelta, new bytes(0)))
            );

            ops[2] = ISuperfluid.Operation(
                BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
                address(cfa),
                abi.encode(updateFlowCallAgreemeentCallData, new bytes(0))
            );
        } else {
            ops[0] = ISuperfluid.Operation(
                BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
                address(cfa),
                abi.encode(updateFlowCallAgreemeentCallData, new bytes(0))
            );
        }
    }
}
