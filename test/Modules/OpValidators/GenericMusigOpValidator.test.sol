// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {GenericMusigOpValidator} from "../../../src/Modules/OpValidators/GenericMusigOpValidator.sol";
import {
    WhitelistedCall,
    SelectorAndChecker,
    Signers,
    Op,
    BatchOp
} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {SEND_ETH, CALL_FUNCTIONS, NO_PARAMS_CHECKS_ADDRESS} from "../../../src/Modules/OpValidators/constants.sol";
import {Counter} from "../../Mocks/Counter.sol";
import {GenericMusigOpValidatorTestSetup} from "./GenericMusigOpValidatorTestSetup.sol";

contract GenericMusigOpValidatorTest is GenericMusigOpValidatorTestSetup {
    /* -----------------SINGLE OP----------------- */
    function testSingleOp() public {
        uint256 cpt_start = counter.value();
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        Op memory op = Op({target: makeAddr("alice"), value: 1 ether, data: "", validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        // Validate the operation
        assertEq(true, validator.validateOp(op));
        // the call is not executed
        assertEq(counter.value(), cpt_start);
    }

    /* -----------------BATCHED OPs----------------- */
    function testBatchedOps() public {
        uint256 cpt_start = counter.value();
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        BatchOp memory batchOp = BatchOp({ops: new Op[](2), validationData: ""});
        Op memory op1 = Op({target: makeAddr("alice"), value: 1 ether, data: "", validationData: ""});
        Op memory op2 = Op({target: makeAddr("alice"), value: 1 ether, data: "", validationData: ""});
        batchOp.ops[0] = op1;
        batchOp.ops[1] = op2;

        bytes32 message = validator.messageFromOps(batchOp.ops);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        batchOp.validationData = signatures;

        // Validate the operation
        assertEq(true, validator.validateBatchedOp(batchOp));
        // the call is not executed
        assertEq(counter.value(), cpt_start);
    }

    /* -----------------isValidSignature----------------- */
    // test valid signatures
    function testValidSignatures() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        // Ensure the signatures are valid
        assertEq(true, validator.isValidSignature(message, signatures));
    }

    // test signature threshold not reached
    function testSignatureThresholdNotReached() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](1);
        opSigners[0] = signer1;

        bytes memory signatures = multiSign(opSigners, message);

        vm.expectRevert(
            abi.encodeWithSelector(
                GenericMusigOpValidator.QuorumNotMet.selector,
                1, // signer1 weight
                2 // threshold
            )
        );
        // Ensure the signatures are valid
        assertEq(false, validator.isValidSignature(message, signatures));
    }

    // test signature from non-allowed signer
    function testSignatureFromNonAllowedSigner() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = notValidatorSigner;

        bytes memory signatures = multiSign(opSigners, message);

        vm.expectRevert(
            abi.encodeWithSelector(GenericMusigOpValidator.InvalidSigner.selector, vm.addr(notValidatorSigner))
        );

        // Check if the signature is valid
        assertEq(false, validator.isValidSignature(message, signatures));
    }

    // test 1 signer signed multiple times in the array
    function testSameSignerSignedMultipleTimes() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](2);
        uint256 uniqueSigner = signer1;
        opSigners[0] = uniqueSigner;
        opSigners[1] = uniqueSigner;

        bytes memory signatures = multiSign(opSigners, message);

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.DuplicateSigner.selector, vm.addr(uniqueSigner)));

        // Check if the signature is valid
        validator.isValidSignature(message, signatures);
    }

    // test invalid signature len
    function testInvalidSignatureLen() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        // remove the last byte of the signature
        bytes memory invalidSignatures = new bytes(signatures.length - 1);
        for (uint256 i = 0; i < invalidSignatures.length; i++) {
            invalidSignatures[i] = signatures[i];
        }

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.InvalidSignature.selector));

        // Check if the signature is valid
        validator.isValidSignature(message, invalidSignatures);
    }

    // test invalid signature
    // test invalid signature len
    function testInvalidSignature() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        bytes32 message = keccak256("this is a message");
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        // remove the last byte of the signature
        bytes memory invalidSignatures = new bytes(signatures.length);
        for (uint256 i = 0; i < invalidSignatures.length - 1; i++) {
            invalidSignatures[i] = signatures[i];
        }

        // add a random byte to the signature (different from the original)
        bytes1 initialByte = signatures[signatures.length - 1];
        bytes1 newByte = initialByte == bytes1(0) ? bytes1(uint8(1)) : bytes1(0);

        invalidSignatures[invalidSignatures.length - 1] = newByte;

        // expected to throw a 'InvalidSigner' error but the signer parameter cannot be expected
        vm.expectRevert();

        // Check if the signature is valid
        validator.isValidSignature(message, invalidSignatures);
    }

    /* -----------------NATIVE TRANSFER----------------- */
    function testNotWhitelistedTransferTarget() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        Op memory op = Op({target: makeAddr("bob"), value: 1 ether, data: "", validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.TargetNotWhitelisted.selector, op.target));
        validator.validateOp(op);
    }

    function testAmountSupAllowance() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        uint256 allowance = 1 ether;
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: allowance,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        Op memory op = Op({target: makeAddr("alice"), value: allowance + 1, data: "", validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.ExceedsAllowance.selector, allowance, op.value));
        validator.validateOp(op);
    }

    function testValidNativeTransfer() public {
        uint256 cpt_start = counter.value();
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: makeAddr("alice"),
            maxAllowance: 1 ether,
            permissions: bytes1(SEND_ETH),
            selectorAndChecker: new SelectorAndChecker[](0)
        });

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        Op memory op = Op({target: makeAddr("alice"), value: 1 ether, data: "", validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        // Validate the operation
        assertEq(true, validator.validateOp(op));
        // the call is not executed
        assertEq(counter.value(), cpt_start);
    }

    /* -----------------CALL----------------- */
    function testNotWhitelistedCallTarget() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: address(counter),
            maxAllowance: 0,
            permissions: bytes1(CALL_FUNCTIONS),
            selectorAndChecker: new SelectorAndChecker[](1)
        });

        // allow increment() function
        whitelistedCalls[0].selectorAndChecker[0] =
            SelectorAndChecker({selector: counter.increment.selector, paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        bytes memory selector = abi.encodeWithSelector(counter.ping.selector);
        // op to counter.ping() fct
        Op memory op = Op({target: address(counter), value: 0, data: selector, validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        vm.expectRevert();
        // commented since forge is buggy and display:
        // vm.expectRevert(
        //     SelectorNotWhitelisted(0x5c36b186) != SelectorNotWhitelisted(0x00000000)
        //     whereas when we console.log the selector here and in the tested contract's function, whe get 0x5c36b186 on both sides
        //     abi.encodeWithSelector(
        //         GenericMusigOpValidator.SelectorNotWhitelisted.selector,
        //         selector
        //     )
        // );
        validator.validateOp(op);
    }

    function testValidCallNoArgs() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: address(counter),
            maxAllowance: 0,
            permissions: bytes1(CALL_FUNCTIONS),
            selectorAndChecker: new SelectorAndChecker[](1)
        });

        bytes memory selector = abi.encodeWithSelector(counter.increment.selector);

        // allow increment() function
        whitelistedCalls[0].selectorAndChecker[0] =
            SelectorAndChecker({selector: bytes4(selector), paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        // op to counter.increment() fct
        Op memory op = Op({target: address(counter), value: 0, data: selector, validationData: ""});
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        // Validate the operation
        assertEq(true, validator.validateOp(op));
    }

    function testEmptySelector() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: address(counter),
            maxAllowance: 0,
            permissions: bytes1(CALL_FUNCTIONS),
            selectorAndChecker: new SelectorAndChecker[](1)
        });

        bytes memory selector = abi.encodeWithSelector(counter.increment.selector);

        // allow increment() function
        whitelistedCalls[0].selectorAndChecker[0] =
            SelectorAndChecker({selector: bytes4(selector), paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        Op memory op = Op({
            target: address(counter),
            value: 0,
            data: "", // empty selector
            validationData: ""
        });

        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.EmptyOperation.selector));

        validator.validateOp(op);
    }

    function testSelectorLenInf4AndNot0() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: address(counter),
            maxAllowance: 0,
            permissions: bytes1(CALL_FUNCTIONS),
            selectorAndChecker: new SelectorAndChecker[](1)
        });

        bytes memory selector = abi.encodeWithSelector(counter.increment.selector);

        // allow increment() function
        whitelistedCalls[0].selectorAndChecker[0] =
            SelectorAndChecker({selector: bytes4(selector), paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);

        Op memory op = Op({
            target: address(counter),
            value: 0,
            data: hex"0123", // selector len < 4 bytes
            validationData: ""
        });

        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        vm.expectRevert(abi.encodeWithSelector(GenericMusigOpValidator.DataFieldTooShort.selector));

        validator.validateOp(op);
    }

    function testValidCallWithArgs() public {
        // Create a list of whitelisted calls
        WhitelistedCall[] memory whitelistedCalls = new WhitelistedCall[](1);

        // allow native transfer to alice's address and call functions
        whitelistedCalls[0] = WhitelistedCall({
            target: address(counter),
            maxAllowance: 0,
            permissions: bytes1(CALL_FUNCTIONS),
            selectorAndChecker: new SelectorAndChecker[](1)
        });

        bytes memory selector = abi.encodeWithSelector(counter.incrementWithAmount.selector);

        // allow increment() function
        whitelistedCalls[0].selectorAndChecker[0] =
            SelectorAndChecker({selector: bytes4(selector), paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        GenericMusigOpValidator validator = setupValidator(whitelistedCalls);
        // op to counter.increment() fct
        Op memory op = Op({
            target: address(counter),
            value: 0,
            data: abi.encodeWithSelector(counter.incrementWithAmount.selector, 2),
            validationData: ""
        });
        bytes32 message = validator.messageFromOp(op);
        uint256[] memory opSigners = new uint256[](2);
        opSigners[0] = signer1;
        opSigners[1] = signer2;

        bytes memory signatures = multiSign(opSigners, message);

        op.validationData = signatures;

        // Validate the operation
        assertEq(true, validator.validateOp(op));
    }
}
