// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {
    Op, BatchOp, IOpValidatorModule, WhitelistedCall, Signers
} from "../../interfaces/modules/IOpValidatorModule.sol";
import {IParameterValidator} from "../../interfaces/modules/IParameterValidator.sol";
import {NO_PARAMS_CHECKS_ADDRESS, SEND_ETH, CALL_FUNCTIONS} from "./constants.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {console} from "forge-std/console.sol";

contract GenericMusigOpValidator is IOpValidatorModule {
    using MessageHashUtils for bytes32;

    /* -------------MUSIG VARIABLES------------- */
    // Sum of all the signer's weight
    uint256 public totalWeight = 0;
    // Sum of all signer's weight needed to
    uint256 public quorum = 0;

    // Mapping to store the signers and their weight in the musig
    mapping(address => uint256) public signers;

    /* -------------CALL WHITELISTS------------- */
    // Mapping to store whitelisted target addresses
    mapping(address => bytes1) public whitelistedAddresses;

    // Mapping to store max ETH allowance per target
    // MAX VALUE SENDABLE TO THE TARGET IN 1 OP. CAN BE CALLED MULTIPLE TIMES
    // todo: add frequency / 1 time checks
    mapping(address => uint256) public maxAllowance;

    // Mapping to store whitelisted function selectors per target
    mapping(address => mapping(bytes4 => address)) public whitelistedSelectors;

    // Events
    event TargetWhitelisted(address indexed target, uint256 allowance);
    event TargetRemoved(address indexed target);
    event SelectorWhitelisted(address indexed target, bytes4 indexed selector);
    event SelectorRemoved(address indexed target, bytes4 indexed selector);

    // Errors
    error TargetNotWhitelisted(address target);
    error SelectorNotWhitelisted(bytes4 selector);
    error ExceedsAllowance(uint256 allowance, uint256 value);
    error ParameterValidationFailed();
    error InvalidSignature();
    error InvalidSigner(address signer);
    error ZeroAddress();
    error InvalidPermissions();
    error InvalidSignerWeight();
    error EmptyWhitelistOrSigners();
    error DuplicateSigner(address signer);
    error QuorumNotMet(uint256 totalSigWeight, uint256 quorum);
    error EmptyOperation();
    error DataFieldTooShort();

    constructor(WhitelistedCall[] memory whitelist, Signers[] memory signers_, uint256 quorum_) {
        if (whitelist.length == 0 || signers_.length == 0) {
            revert EmptyWhitelistOrSigners();
        }

        if (quorum_ == 0) revert("Quorum cannot be zero");

        quorum = quorum_;

        // Set the signers and their weights
        for (uint256 i = 0; i < signers_.length; i++) {
            address signer = signers_[i].signer;
            uint256 weight = signers_[i].weight;

            if (signer == address(0)) revert ZeroAddress();
            if (weight == 0) revert InvalidSignerWeight();

            signers[signer] = weight;
            totalWeight += weight;
        }

        // Set the whitelisted actions
        for (uint256 i = 0; i < whitelist.length; i++) {
            WhitelistedCall memory call = whitelist[i];

            // whitelist the call
            _whitelist(call);
        }
    }

    function validateOp(Op calldata op) public view returns (bool) {
        bytes32 message = messageFromOp(op);

        if (!isValidSignature(message, op.validationData)) {
            revert InvalidSignature();
        }

        return _validateOp(op);
    }

    function validateBatchedOp(BatchOp calldata batch) external view returns (bool) {
        bytes32 message = messageFromOps(batch.ops);

        if (!isValidSignature(message, batch.validationData)) {
            revert InvalidSignature();
        }

        for (uint256 i = 0; i < batch.ops.length; i++) {
            if (!_validateOp(batch.ops[i])) {
                return false;
            }
        }
        return true;
    }

    // whitelist a call
    function _whitelist(WhitelistedCall memory call) private {
        if (call.target == address(0)) revert ZeroAddress();
        if (call.permissions == 0) revert InvalidPermissions();

        // if call is allowed, ensure there is at least 1 selector allowed
        if ((call.permissions & bytes1(CALL_FUNCTIONS)) != 0 && call.selectorAndChecker.length == 0) {
            revert InvalidPermissions();
        }

        if (call.maxAllowance > 0) {
            maxAllowance[call.target] = call.maxAllowance;
            emit TargetWhitelisted(call.target, call.maxAllowance);
        }
        whitelistedAddresses[call.target] = call.permissions;

        for (uint256 i = 0; i < call.selectorAndChecker.length; i++) {
            bytes4 selector = call.selectorAndChecker[i].selector;
            address paramsValidator = call.selectorAndChecker[i].paramsValidator;

            if (paramsValidator == address(0)) {
                revert ZeroAddress();
            }

            whitelistedSelectors[call.target][selector] = paramsValidator;
            emit SelectorWhitelisted(call.target, selector);
        }
    }

    // todo: use bls signatures for better gas efficiency
    function isValidSignature(bytes32 message, bytes memory signatures) public view returns (bool) {
        uint256 allSignaturesLen = signatures.length;

        // ensure the data length is correct
        if (allSignaturesLen % 65 != 0) {
            revert InvalidSignature();
        }

        // decode the signatures
        uint256 sigCount = allSignaturesLen / 65;
        uint256 totalSigWeight = 0;
        address[] memory signersList = new address[](sigCount);

        // Process each signature
        for (uint256 i = 0; i < sigCount; i++) {
            uint256 offset = i * 65;

            // Extract r, s, v components
            bytes32 r;
            bytes32 s;
            uint8 v;

            assembly {
                // Calculate memory position for r (32 bytes)
                r := mload(add(add(signatures, 32), offset))

                // Calculate memory position for s (32 bytes)
                s := mload(add(add(signatures, 64), offset))

                // Calculate memory position for v (1 byte)
                v := byte(0, mload(add(add(signatures, 96), offset)))
            }

            // Normalize v value (add 27 if needed)
            if (v < 27) {
                v += 27;
            }

            // Verify the signature
            address signer = ecrecover(message, v, r, s);

            uint256 weight = signers[signer];
            if (weight == 0) {
                revert InvalidSigner(signer);
            }

            // Ensure each signature is from a unique signer
            for (uint256 j = 0; j < signersList.length; j++) {
                if (signersList[j] == signer) {
                    revert DuplicateSigner(signer);
                }
            }

            // Store the signer in the list
            signersList[i] = signer;

            totalSigWeight += weight;
        }

        // Check if the total signature weight meets the quorum
        if (totalSigWeight < quorum) {
            revert QuorumNotMet(totalSigWeight, quorum);
        }

        return true;
    }

    function _validateOp(Op calldata op) internal view returns (bool) {
        address target = op.target;
        uint256 value = op.value;

        // Ensure call is whitelisted
        uint8 authorization = uint8(whitelistedAddresses[target]);
        if (authorization == 0) revert TargetNotWhitelisted(target);

        // Block empty operations (this is a no-op but can still trigger the fallback leading to unexpected behavior)
        if (value == 0 && op.data.length == 0) {
            revert EmptyOperation();
        }

        if ((value > 0 && (authorization & SEND_ETH) == 0) || (value > maxAllowance[target])) {
            revert ExceedsAllowance(maxAllowance[target], value);
        }

        uint256 dataLen = op.data.length;
        if (dataLen > 0 && dataLen < 4) revert DataFieldTooShort();

        if (dataLen > 0 && (authorization & CALL_FUNCTIONS) == 0) {
            revert TargetNotWhitelisted(target);
        }

        // Ensure function selector is whitelisted
        if (dataLen >= 4) {
            bytes4 selector = bytes4(op.data[:4]);
            address paramsValidator = whitelistedSelectors[target][selector];
            if (paramsValidator == address(0)) {
                revert SelectorNotWhitelisted(selector);
            }
            if (paramsValidator != NO_PARAMS_CHECKS_ADDRESS && dataLen > 4) {
                bytes memory data = op.data[4:];
                // Validate parameters
                IParameterValidator validator = IParameterValidator(paramsValidator);
                if (!validator.validateParameters(data)) {
                    revert ParameterValidationFailed();
                }
            }
        }

        return true;
    }

    function messageFromOps(Op[] calldata ops) public view returns (bytes32) {
        bytes memory combinedData = new bytes(0);

        // add the chainId and msg.sender to the combinedData
        combinedData = abi.encodePacked(block.chainid, msg.sender);

        // Concatenate the encoding of each operation
        for (uint256 i = 0; i < ops.length; i++) {
            combinedData = abi.encodePacked(combinedData, abi.encodePacked(ops[i].target, ops[i].value, ops[i].data));
        }

        // Create the hash in the Ethereum format
        return keccak256(combinedData).toEthSignedMessageHash();
    }

    function messageFromOp(Op calldata op) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, msg.sender, op.target, op.value, op.data))
            .toEthSignedMessageHash();
    }
}
