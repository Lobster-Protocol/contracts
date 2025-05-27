// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {VaultWithOperationModuleTestSetup} from "./VaultSetups/WithDummyModules/VaultWithOperationModuleTestSetup.sol";
// import {SimpleVaultTestSetup} from "./VaultSetups/SimpleVaultTestSetup.sol";
import {BaseOp, Op, BatchOp} from "../../src/interfaces/modules/IOpValidatorModule.sol";
import {Modular} from "../../src/Modules/Modular.sol";
import {AUTHORIZED, UNAUTHORIZED} from "../Mocks/modules/DummyValidator.sol";

contract ExecuteOpsTest is VaultWithOperationModuleTestSetup {
    /* --------------------SINGLE OP--------------------*/
    function testApprovedOp() public {
        uint256 initial_value = counter.value();

        Op memory op = Op(BaseOp(address(counter), 0, abi.encodeWithSelector(AUTHORIZED)), "");

        vault.executeOp(op);

        assertEq(counter.value(), initial_value + 1);
    }

    function testDeniedOp() public {
        Op memory op = Op(
            BaseOp(address(counter), 0, abi.encodeWithSelector(counter.increment.selector)),
            abi.encodePacked(UNAUTHORIZED)
        );

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOp(op);
    }

    /* --------------------BATCHED OPS--------------------*/
    function testApprovedOps() public {
        uint256 initial_value = counter.value();

        BatchOp memory batch = BatchOp({ops: new BaseOp[](2), validationData: abi.encodePacked(AUTHORIZED)});

        BaseOp memory op1 = BaseOp(address(counter), 0, abi.encodeWithSelector(counter.increment.selector));
        BaseOp memory op2 = BaseOp(address(counter), 0, abi.encodeWithSelector(counter.increment.selector));

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vault.executeOpBatch(batch);

        assertEq(counter.value(), initial_value + 2);
    }

    function testDeniedOps() public {
        BatchOp memory batch = BatchOp({ops: new BaseOp[](2), validationData: abi.encodePacked(UNAUTHORIZED)});

        BaseOp memory op1 = BaseOp(address(counter), 0, abi.encodeWithSelector(counter.increment.selector));
        BaseOp memory op2 = BaseOp(address(counter), 0, abi.encodeWithSelector(counter.increment.selector));

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOpBatch(batch);
    }
}
