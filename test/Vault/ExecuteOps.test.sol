// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {VaultWithValidatorTestSetup} from "./VaultSetups/WithDummyModules/VaultWithValidatorTestSetup.sol";
import {VaultWithValidatorAndHookTestSetup} from "./VaultSetups/WithDummyModules/VaultWithValidatorAndHookTestSetup.sol";
import {SimpleVaultTestSetup} from "./VaultSetups/SimpleVaultTestSetup.sol";
import {BatchOp, Op} from "../../src/interfaces/modules/IOpValidatorModule.sol";
import {Modular} from "../../src/Modules/Modular.sol";
import {AUTHORIZED, UNAUTHORIZED} from "../Mocks/modules/DummyValidator.sol";
import {DummyHook, UNAUTHORIZED_POSTHOOK, UNAUTHORIZED_PREHOOK} from "../Mocks/modules/DummyHook.sol";

contract ExecuteOpsNoHookTest is VaultWithValidatorTestSetup {
    function hookNotSet() private view {
        require(address(vault.hook()) == address(0), "Hook set whereas we don't want it");
    }

    /* --------------------SINGLE OP--------------------*/
    function testApprovedOp() public {
        hookNotSet();

        uint256 initial_value = counter.value();

        Op memory op =
            Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), abi.encodePacked(AUTHORIZED));

        vault.executeOp(op);

        assertEq(counter.value(), initial_value + 1);
    }

    function testDeniedOp() public {
        hookNotSet();

        Op memory op =
            Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), abi.encodePacked(UNAUTHORIZED));

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOp(op);
    }

    /* --------------------BATCHED OPS--------------------*/
    function testApprovedOps() public {
        hookNotSet();

        uint256 initial_value = counter.value();

        BatchOp memory batch = BatchOp({ops: new Op[](2), validationData: abi.encodePacked(AUTHORIZED)});

        Op memory op1 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");
        Op memory op2 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vault.executeOpBatch(batch);

        assertEq(counter.value(), initial_value + 2);
    }

    function testDeniedOps() public {
        hookNotSet();

        BatchOp memory batch = BatchOp({ops: new Op[](2), validationData: abi.encodePacked(UNAUTHORIZED)});

        Op memory op1 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");
        Op memory op2 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOpBatch(batch);
    }
}

contract ExecuteOpsWithHookTest is VaultWithValidatorAndHookTestSetup {
    function hookSet() private view {
        require(address(vault.hook()) != address(0), "Hook not set whereas we need it");
    }

    /* --------------------SINGLE OP--------------------*/
    function testApprovedOp() public {
        hookSet();

        Op memory op =
            Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), abi.encodePacked(AUTHORIZED));

        // the execution is expected to be smooth (will revert if pre or post check fails)
        vault.executeOp(op);
    }

    function testDeniedByPreHookOp() public {
        hookSet();

        Op memory op = Op(
            address(counter),
            0,
            abi.encodeWithSelector(counter.increment.selector),
            abi.encodePacked(UNAUTHORIZED_PREHOOK)
        );

        vm.expectRevert(Modular.PreHookFailed.selector);
        vault.executeOp(op);
    }

    function testDeniedByPostHookOp() public {
        hookSet();

        Op memory op = Op(
            address(counter),
            0,
            abi.encodeWithSelector(counter.increment.selector),
            abi.encodePacked(UNAUTHORIZED_POSTHOOK)
        );

        vm.expectRevert(Modular.PostHookFailed.selector);
        vault.executeOp(op);
    }

    // /* --------------------BATCHED OPS--------------------*/
    function testApprovedOps() public {
        hookSet();

        uint256 initial_value = counter.value();

        BatchOp memory batch = BatchOp({ops: new Op[](2), validationData: abi.encodePacked(AUTHORIZED)});

        Op memory op1 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");
        Op memory op2 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vault.executeOpBatch(batch);

        assertEq(counter.value(), initial_value + 2);
    }

    function testDeniedOps() public {
        hookSet();

        BatchOp memory batch = BatchOp({ops: new Op[](2), validationData: abi.encodePacked(AUTHORIZED)});

        Op memory op1 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");
        Op memory op2 = Op(
            address(counter),
            0,
            abi.encodeWithSelector(counter.increment.selector),
            abi.encodePacked(UNAUTHORIZED_POSTHOOK) // supposed to be empty but analyzed by the dummy hook to know if it needs to revert
        );

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vm.expectRevert(Modular.PostHookFailed.selector);
        vault.executeOpBatch(batch);
    }
}

// ensure executeOps function throw when no validator is set
contract ExecuteOpsNoValidatorTest is SimpleVaultTestSetup {
    function testExecuteOp() public {
        Op memory op =
            Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), abi.encodePacked(AUTHORIZED));

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOp(op);
    }

    function testExecuteBatchedOps() public {
        BatchOp memory batch = BatchOp({ops: new Op[](2), validationData: abi.encodePacked(AUTHORIZED)});

        Op memory op1 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");
        Op memory op2 = Op(address(counter), 0, abi.encodeWithSelector(counter.increment.selector), "");

        batch.ops[0] = op1;
        batch.ops[1] = op2;

        vm.expectRevert(Modular.OpNotApproved.selector);
        vault.executeOpBatch(batch);
    }
}

// todo: test when a hook calls executeOp and executeBatchedOps
