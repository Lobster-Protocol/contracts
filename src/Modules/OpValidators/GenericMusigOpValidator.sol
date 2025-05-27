// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {
    BaseOp,
    Op,
    BatchOp,
    IOpValidatorModule,
    WhitelistedCall,
    Signer
} from "../../interfaces/modules/IOpValidatorModule.sol";
import {IParameterValidator} from "../../interfaces/modules/IParameterValidator.sol";
import {NO_PARAMS_CHECKS_ADDRESS, SEND_ETH, CALL_FUNCTIONS} from "./constants.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// Offset for the nonce in the validation data
uint256 constant NONCE_OFFSET = 32;

/**
 * @title GenericMuSigOpValidator
 * @author Lobster
 * @notice An operation validator module that uses multi-signature (musig) validation with quorum-based approval
 * @dev This validator implements whitelist-based operation validation with parameter verification
 *      and multi-signature authorization with customizable signer weights and quorum requirements
 * @dev Once deployed, it is no longer possible to update the call whitelist but you can still update the signers.
 */
contract GenericMuSigOpValidator is IOpValidatorModule {
    // todo: support eip-712 signatures & message signing that are not vault transactions
    using MessageHashUtils for bytes32;

    /// @notice The vault address this validator is associated with
    address public vault;

    /* -------------MUSIG VARIABLES------------- */
    /// @notice Sum of all signers' weights
    uint256 public totalWeight = 0;

    /// @notice Minimum signature weight required to approve operations
    uint256 public quorum = 0;

    /// @notice Nonce for the next operation (prevents replay attacks)
    uint256 public nextNonce = 0;

    /// @notice Mapping to store the signers and their weight in the musig
    mapping(address => uint256) public signers;

    /* -------------CALL WHITELISTS------------- */
    /// @notice Mapping to store whitelisted target addresses and their permissions
    mapping(address => bytes1) public whitelistedAddresses;

    /// @notice Mapping to store max ETH allowance per target
    /// @dev MAX VALUE SENDABLE TO THE TARGET IN 1 OP. CAN BE CALLED MULTIPLE TIMES
    /// todo: add frequency / 1 time checks
    mapping(address => uint256) public maxAllowance;

    /// @notice Mapping to store whitelisted function selectors per target with their parameter validators
    mapping(address => mapping(bytes4 => address)) public whitelistedSelectors;

    /**
     * @notice Emitted when a target address is whitelisted
     * @param target The whitelisted address
     * @param allowance The maximum ETH value that can be sent to this target
     */
    event TargetWhitelisted(address indexed target, uint256 allowance);

    /**
     * @notice Emitted when a function selector is whitelisted for a target
     * @param target The target address
     * @param selector The function selector
     */
    event SelectorWhitelisted(address indexed target, bytes4 indexed selector);

    /**
     * @notice Emitted when a new signer is added to the multisig
     * @param signer The address of the new signer
     * @param weight The weight of the new signer
     */
    event SignerAdded(address indexed signer, uint256 weight);

    /**
     * @notice Emitted when signers configuration is updated
     * @param newQuorum The new quorum value
     * @param newTotalWeight The new total weight of all signers
     */
    event SignersUpdated(address indexed signer, uint256 weight, uint256 newQuorum, uint256 newTotalWeight);

    /// @notice Thrown when an operation targets a non-whitelisted address
    error TargetNotWhitelisted(address target);
    /// @notice Thrown when a function selector is not whitelisted for the target
    error SelectorNotWhitelisted(bytes4 selector);
    /// @notice Thrown when an operation exceeds the maximum allowance for a target
    error ExceedsAllowance(uint256 allowance, uint256 value);
    /// @notice Thrown when parameter validation fails
    error ParameterValidationFailed();
    /// @notice Thrown when a signature is invalid
    error InvalidSignature();
    /// @notice Thrown when a signer is not in the signers list
    error InvalidSigner(address signer);
    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();
    /// @notice Thrown when invalid permissions are set
    error InvalidPermissions();
    /// @notice Thrown when a signer has an invalid weight
    error InvalidSignerWeight();
    /// @notice Thrown when the whitelist or signers list is empty
    error EmptyWhitelistOrSigners();
    /// @notice Thrown when a signer appears multiple times in signatures
    error DuplicateSigner(address signer);
    /// @notice Thrown when signatures don't meet the required quorum
    error QuorumNotMet(uint256 totalSigWeight, uint256 quorum);
    /// @notice Thrown when an empty operation is submitted
    error EmptyOperation();
    /// @notice Thrown when data field is too short to extract a selector
    error DataFieldTooShort();
    /// @notice Thrown when an incorrect nonce is provided
    error InvalidNonce(uint256 nonce, uint256 nextNonce);
    /// @notice Thrown when a function is called by an address other than the vault
    error NotVault();
    /// @notice Thrown when the vault is not initialized
    error VaultNotInitialized();
    /// @notice Thrown when trying to set the vault after it's already set
    error VaultAlreadySet();

    /**
     * @notice Restricts function access to the vault address
     * @dev Reverts if the caller is not the vault or if vault is not set
     */
    modifier onlyVault() {
        if (msg.sender != vault) {
            if (vault == address(0)) revert VaultNotInitialized();
            revert NotVault();
        }
        _;
    }

    /**
     * @notice Constructs a new GenericMuSigOpValidator
     * @param whitelist Array of whitelisted calls with their targets, permissions, and selectors
     * @param signers_ Array of signers with their weights
     * @param quorum_ Minimum signature weight required to approve operations
     * @dev This sets up the initial whitelist and signer configuration
     */
    constructor(WhitelistedCall[] memory whitelist, Signer[] memory signers_, uint256 quorum_) {
        uint256 whitelistLength = whitelist.length;
        uint256 signersLength = signers_.length;

        if (whitelistLength == 0 || signersLength == 0) {
            revert EmptyWhitelistOrSigners();
        }

        if (quorum_ == 0) revert("Quorum cannot be zero");

        quorum = quorum_;

        // Set the signers and their weights
        for (uint256 i = 0; i < signersLength; ++i) {
            address signer = signers_[i].signer;
            uint256 weight = signers_[i].weight;

            if (signer == address(0)) revert ZeroAddress();
            if (weight == 0) revert InvalidSignerWeight();

            signers[signer] = weight;
            totalWeight += weight;

            emit SignerAdded(signer, weight);
        }

        // Set the whitelisted actions
        for (uint256 i = 0; i < whitelistLength; ++i) {
            WhitelistedCall memory call = whitelist[i];

            // whitelist the call
            _whitelist(call);
        }
    }

    /**
     * @dev See {IOpValidatorModule-validateOp}.
     */
    function validateOp(Op calldata op) public onlyVault returns (bool result) {
        result = validateOpView(op);
        // Increment the nonce after the operation is validated
        nextNonce++;
    }

    /**
     * @notice Validates an operation without incrementing the nonce
     * It is used to preview the operation verification without changing state
     * @param op The operation to validate
     * @return result True if the operation is valid
     * @dev Used to preview operation verification without changing state
     */
    function validateOpView(Op calldata op) public view returns (bool result) {
        // Ensure nonce validity
        checkNonce(uint256(bytes32(op.validationData[:NONCE_OFFSET])));

        bytes32 message = messageFromOp(op);

        if (!isValidSignature(message, op.validationData[NONCE_OFFSET:])) {
            revert InvalidSignature();
        }

        result = _validateBaseOp(op.base);
    }

    /**
     * @dev See {IOpValidatorModule-validateBatchedOp}.
     */
    function validateBatchedOp(BatchOp calldata batch) external onlyVault returns (bool result) {
        result = validateBatchedOpView(batch);
        // Increment the nonce after all operations are validated
        nextNonce++;

        return true;
    }

    /**
     * @notice Validates a batch of operations without incrementing the nonce
     * It is used to preview the operation verification without changing state
     * @param batch The batch operation to validate
     * @return True if all operations in the batch are valid
     * @dev Used to preview batch operation verification without changing state
     */
    function validateBatchedOpView(BatchOp calldata batch) public view returns (bool) {
        // Ensure nonce validity
        checkNonce(uint256(bytes32(batch.validationData[:NONCE_OFFSET])));

        bytes32 message = messageFromOps(batch.ops);

        if (!isValidSignature(message, batch.validationData[NONCE_OFFSET:])) {
            revert InvalidSignature();
        }

        uint256 batchLength = batch.ops.length;

        for (uint256 i = 0; i < batchLength; ++i) {
            if (!_validateBaseOp(batch.ops[i])) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Whitelists a call configuration
     * @param call The call configuration to whitelist
     * @dev Internal function to add a target, its permissions, and selectors to the whitelist
     */
    function _whitelist(WhitelistedCall memory call) private {
        if (call.target == address(0)) revert ZeroAddress();
        if (call.permissions == 0) revert InvalidPermissions();

        uint256 callSelectorAndCheckerLength = call.selectorAndChecker.length;

        // if call is allowed, ensure there is at least 1 selector allowed
        if ((call.permissions & bytes1(CALL_FUNCTIONS)) != 0 && callSelectorAndCheckerLength == 0) {
            revert InvalidPermissions();
        }

        if (call.maxAllowance > 0) {
            maxAllowance[call.target] = call.maxAllowance;
            emit TargetWhitelisted(call.target, call.maxAllowance);
        }
        whitelistedAddresses[call.target] = call.permissions;

        for (uint256 i = 0; i < callSelectorAndCheckerLength; ++i) {
            bytes4 selector = call.selectorAndChecker[i].selector;
            address paramsValidator = call.selectorAndChecker[i].paramsValidator;

            if (paramsValidator == address(0)) {
                revert ZeroAddress();
            }

            whitelistedSelectors[call.target][selector] = paramsValidator;
            emit SelectorWhitelisted(call.target, selector);
        }
    }

    /**
     * @notice Verifies if a set of signatures is valid for a message
     * @param message The message hash that was signed
     * @param signatures Concatenated signatures (65 bytes each)
     * @return True if the signatures are valid and meet the quorum
     * @dev Verifies each signature, checks signer validity, and calculates total weight
     * @dev todo: use bls signatures for better gas efficiency
     */
    function isValidSignature(bytes32 message, bytes memory signatures) public view returns (bool) {
        uint256 allSignaturesLength = signatures.length;

        // ensure the data length is correct
        if (allSignaturesLength % 65 != 0) {
            revert InvalidSignature();
        }

        // decode the signatures
        uint256 sigCount = allSignaturesLength / 65;
        uint256 totalSigWeight = 0;
        address[] memory signersList = new address[](sigCount);

        // Process each signature
        for (uint256 i = 0; i < sigCount; ++i) {
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

            // Ensure signer is not zero
            if (signer == address(0)) {
                revert InvalidSignature();
            }

            uint256 weight = signers[signer];
            if (weight == 0) {
                revert InvalidSigner(signer);
            }

            // Ensure each signature is from a unique signer
            for (uint256 j = 0; j < sigCount; j++) {
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

    /**
     * @notice Validates a base operation
     * @param op The base operation to validate
     * @return True if the operation is valid
     * @dev Checks target whitelist, value allowance, function selector whitelist, and parameters
     */
    function _validateBaseOp(BaseOp calldata op) internal view returns (bool) {
        address target = op.target;
        uint256 value = op.value;

        // Ensure call is whitelisted
        uint8 authorization = uint8(whitelistedAddresses[target]);
        if (authorization == 0) revert TargetNotWhitelisted(target);

        uint256 dataLength = op.data.length;

        // Block empty operations (this is a no-op but can still trigger the fallback leading to unexpected behavior)
        if (value == 0 && dataLength == 0) {
            revert EmptyOperation();
        }

        if ((value > 0 && (authorization & SEND_ETH) == 0) || (value > maxAllowance[target])) {
            revert ExceedsAllowance(maxAllowance[target], value);
        }

        if (dataLength > 0 && dataLength < 4) revert DataFieldTooShort();

        if (dataLength > 0 && (authorization & CALL_FUNCTIONS) == 0) {
            revert TargetNotWhitelisted(target);
        }

        // Ensure function selector is whitelisted
        if (dataLength >= 4) {
            bytes4 selector = bytes4(op.data[:4]);
            address paramsValidator = whitelistedSelectors[target][selector];
            if (paramsValidator == address(0)) {
                revert SelectorNotWhitelisted(selector);
            }
            if (paramsValidator != NO_PARAMS_CHECKS_ADDRESS && dataLength > 4) {
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

    /**
     * @notice Creates a message hash from an array of base operations
     * @param ops The array of base operations
     * @return The Ethereum signed message hash
     * @dev Used for batch operation signature verification
     */
    function messageFromOps(BaseOp[] calldata ops) public view returns (bytes32) {
        bytes memory combinedData = new bytes(0);

        // add the chainId and msg.sender to the combinedData
        combinedData = abi.encodePacked(block.chainid, msg.sender);

        uint256 opsLength = ops.length;

        // Concatenate the encoding of each operation
        for (uint256 i = 0; i < opsLength; ++i) {
            combinedData = abi.encodePacked(combinedData, abi.encodePacked(ops[i].target, ops[i].value, ops[i].data));
        }

        // Create the hash in the Ethereum format
        return keccak256(combinedData).toEthSignedMessageHash();
    }

    /**
     * @notice Creates a message hash from a single operation
     * @param op The operation
     * @return The Ethereum signed message hash
     * @dev Used for operation signature verification
     */
    function messageFromOp(Op calldata op) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.chainid, msg.sender, bytes32(op.validationData[:32]), op.base.target, op.base.value, op.base.data
            )
        ).toEthSignedMessageHash(); // nonce
    }

    /**
     * @notice Verifies that the provided nonce matches the expected next nonce
     * @param nonce The nonce to check
     * @dev Prevents replay attacks by ensuring operations are processed in order
     */
    function checkNonce(uint256 nonce) internal view {
        if (nonce != nextNonce) {
            revert InvalidNonce(nonce, nextNonce);
        }
    }

    /**
     * @notice Sets the vault address for this validator
     * @param _vault The vault address to set
     * @param signatures Signatures from authorized signers
     * @dev Can only be called once, requires signatures meeting the quorum
     */
    function setVault(address _vault, bytes calldata signatures) external {
        require(vault == address(0), VaultAlreadySet());
        require(_vault != address(0), ZeroAddress());

        // Create a message hash for signers to sign
        bytes32 messageHash =
            keccak256(abi.encodePacked("GenericMuSigOpValidator_SET_VAULT", _vault)).toEthSignedMessageHash();

        // Verify the signatures meet the quorum
        if (!isValidSignature(messageHash, signatures)) {
            revert InvalidSignature();
        }

        vault = _vault;
    }

    /**
     * @notice Updates the signers, their weights, and the quorum requirement
     * @param newSigner new signer or signer to update with weight
     * @param newQuorum New minimum signature weight required to approve operations
     * @param signatures Signatures from authorized signers meeting the current quorum
     * @dev This function allows for updating the multisig configuration with proper authorization
     * @dev Replaces all existing signers with the new set
     */
    function updateSigner(Signer calldata newSigner, uint256 newQuorum, bytes calldata signatures) external {
        // Verify new configuration is valid
        if (newQuorum == 0) revert("Quorum cannot be zero");

        // Create a message hash for signers to sign
        bytes32 messageHash = _hashSignersData(newSigner, newQuorum);

        // Verify the signatures meet the current quorum
        if (!isValidSignature(messageHash, signatures)) {
            revert InvalidSignature();
        }

        uint256 currentSignerWeight = signers[newSigner.signer];

        if (currentSignerWeight == 0) {
            if (newSigner.weight == 0) revert InvalidSignerWeight();
            signers[newSigner.signer] = newSigner.weight;
            totalWeight += newSigner.weight;
        } else {
            if (newSigner.weight == 0) {
                totalWeight -= currentSignerWeight;
                delete signers[newSigner.signer];
            } else {
                totalWeight = totalWeight - currentSignerWeight + newSigner.weight;
                signers[newSigner.signer] = newSigner.weight;
            }
        }

        emit SignersUpdated(newSigner.signer, newSigner.weight, newQuorum, totalWeight);
    }

    /**
     * @dev Helper function to hash signers data for signature verification
     * @param signer Array of signers with their weights
     * @param newQuorum New minimum signature weight required to approve operations
     * @return Hash of the signers data
     */
    function _hashSignersData(Signer calldata signer, uint256 newQuorum) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("GenericMuSigOpValidator_UPDATE_SIGNERS", signer.signer, signer.weight, newQuorum)
        ).toEthSignedMessageHash();
    }
}
