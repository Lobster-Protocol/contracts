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

/// @dev Offset for the nonce in the validation data (first 32 bytes contain the nonce)
uint256 constant NONCE_OFFSET = 32;

/**
 * @title MuSigOpValidator
 * @author Lobster
 * @notice A multi-signature operation validator that provides secure, quorum-based approval for vault operations.
 * This validator combines whitelist-based operation filtering with multi-signature authorization to ensure
 * only pre-approved operations can be executed by authorized signers meeting a configurable quorum threshold.
 * @dev Key features:
 * - Immutable operation whitelist (set at deployment, cannot be changed)
 * - Mutable signer configuration (signers and quorum can be updated via multi-sig)
 * - Nonce-based replay attack protection
 * - Parameter validation for function calls
 * - Support for both ETH transfers and function calls
 * - Batch operation support for atomic multi-operation execution
 */
contract MuSigOpValidator is IOpValidatorModule {
    using MessageHashUtils for bytes32;

    /// @notice The vault address this validator is bound to (set once during initialization)
    address public vault;

    /* -------------MULTI-SIGNATURE VARIABLES------------- */
    /// @notice Total combined weight of all active signers
    uint256 public totalWeight = 0;

    /// @notice Minimum signature weight required to approve any operation
    uint256 public quorum = 0;

    /// @notice Sequential nonce for operation ordering and replay attack prevention
    uint256 public nextNonce = 0;

    /// @notice Maps signer addresses to their voting weights in the multi-sig scheme
    mapping(address => uint256) public signers;

    /* -------------OPERATION WHITELIST VARIABLES------------- */
    /// @notice Maps target addresses to their permission flags (SEND_ETH | CALL_FUNCTIONS)
    mapping(address => bytes1) public whitelistedAddresses;

    /// @notice Maps target addresses to maximum ETH value allowed per operation
    /// @dev This is per-operation limit, not cumulative. Multiple operations can each send up to this amount
    mapping(address => uint256) public maxAllowance;

    /// @notice Maps target addresses and function selectors to their parameter validator contracts
    /// @dev address(NO_PARAMS_CHECKS_ADDRESS) means no parameter validation is performed
    mapping(address => mapping(bytes4 => address)) public whitelistedSelectors;

    /* -------------EVENTS------------- */
    /**
     * @notice Emitted when a target address is added to the whitelist
     * @param target The whitelisted contract address
     * @param allowance The maximum ETH value that can be sent to this target per operation
     */
    event TargetWhitelisted(address indexed target, uint256 allowance);

    /**
     * @notice Emitted when a function selector is whitelisted for a specific target
     * @param target The target contract address
     * @param selector The 4-byte function selector being whitelisted
     */
    event SelectorWhitelisted(address indexed target, bytes4 indexed selector);

    /**
     * @notice Emitted when a new signer is added to the multi-signature scheme
     * @param signer The address of the new signer
     * @param weight The voting weight assigned to the new signer
     */
    event SignerAdded(address indexed signer, uint256 weight);

    /**
     * @notice Emitted when the signer configuration is updated
     * @param signer The signer address that was added, updated, or removed
     * @param weight The new weight for the signer (0 means removed)
     * @param newQuorum The updated quorum requirement
     * @param newTotalWeight The updated total weight of all active signers
     */
    event SignersUpdated(address indexed signer, uint256 weight, uint256 newQuorum, uint256 newTotalWeight);

    /**
     * @notice Emitted when the quorum requirement is updated
     * @param newQuorum The new minimum signature weight required for operation approval
     */
    event QuorumUpdated(uint256 newQuorum);

    /* -------------CUSTOM ERRORS------------- */
    /// @notice Thrown when attempting to call a non-whitelisted target address
    error TargetNotWhitelisted(address target);
    /// @notice Thrown when attempting to call a non-whitelisted function selector
    error SelectorNotWhitelisted(bytes4 selector);
    /// @notice Thrown when an operation's ETH value exceeds the target's maximum allowance
    error ExceedsAllowance(uint256 allowance, uint256 value);
    /// @notice Thrown when parameter validation fails for a function call
    error ParameterValidationFailed();
    /// @notice Thrown when a signature is malformed or verification fails
    error InvalidSignature();
    /// @notice Thrown when a signature is from an address not in the signers list
    error InvalidSigner(address signer);
    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();
    /// @notice Thrown when invalid permission flags are set for a target
    error InvalidPermissions();
    /// @notice Thrown when a signer is assigned zero or invalid weight
    error InvalidSignerWeight();
    /// @notice Thrown when constructor receives empty whitelist or signers arrays
    error EmptyWhitelistOrSigners();
    /// @notice Thrown when the same signer appears multiple times in a signature set
    error DuplicateSigner(address signer);
    /// @notice Thrown when signature weights don't meet the required quorum
    error QuorumNotMet(uint256 totalSigWeight, uint256 quorum);
    /// @notice Thrown when an operation has no value and no data (meaningless no-op)
    error EmptyOperation();
    /// @notice Thrown when operation data is too short to contain a valid function selector
    error DataFieldTooShort();
    /// @notice Thrown when operation nonce doesn't match expected next nonce
    error InvalidNonce(uint256 nonce, uint256 nextNonce);
    /// @notice Thrown when a function is called by an address other than the associated vault
    error NotVault();
    /// @notice Thrown when vault address is not initialized but required for operation
    error VaultNotInitialized();
    /// @notice Thrown when attempting to set vault address after it's already been set
    error VaultAlreadySet();

    /**
     * @notice Restricts function access to the associated vault address only
     * @dev Provides clear error messages for different failure scenarios
     */
    modifier onlyVault() {
        if (msg.sender != vault) {
            if (vault == address(0)) revert VaultNotInitialized();
            revert NotVault();
        }
        _;
    }

    /**
     * @notice Constructs a new MuSigOpValidator with immutable whitelist and initial signer configuration
     * @param whitelist Array of operation configurations to whitelist (immutable after deployment)
     * @param signers_ Array of initial signers with their voting weights
     * @param quorum_ Minimum signature weight required to approve operations
     * @dev The whitelist cannot be modified after deployment for security reasons.
     * Signers and quorum can be updated later via multi-signature approval.
     * @dev Validates all input parameters and emits events for each configuration
     */
    constructor(WhitelistedCall[] memory whitelist, Signer[] memory signers_, uint256 quorum_) {
        uint256 whitelistLength = whitelist.length;
        uint256 signersLength = signers_.length;

        if (whitelistLength == 0 || signersLength == 0) {
            revert EmptyWhitelistOrSigners();
        }

        if (quorum_ == 0) revert("Quorum cannot be zero");

        quorum = quorum_;

        // Initialize signers and calculate total weight
        for (uint256 i = 0; i < signersLength; ++i) {
            address signer = signers_[i].signer;
            uint256 weight = signers_[i].weight;

            if (signer == address(0)) revert ZeroAddress();
            if (weight == 0) revert InvalidSignerWeight();

            signers[signer] = weight;
            totalWeight += weight;

            emit SignerAdded(signer, weight);
        }

        // Initialize immutable whitelist configuration
        for (uint256 i = 0; i < whitelistLength; ++i) {
            WhitelistedCall memory call = whitelist[i];
            _whitelist(call);
        }
    }

    /**
     * @notice Validates a single operation and increments the nonce if valid
     * @param op The operation to validate including validation data with nonce and signatures
     * @return result True if the operation is valid and properly signed
     * @dev This is the main entry point for vault operation validation.
     * Increments nonce on successful validation to prevent replay attacks.
     */
    function validateOp(Op calldata op) public onlyVault returns (bool result) {
        result = validateOpView(op);
        // Increment nonce after successful validation to prevent replay attacks
        nextNonce++;
    }

    /**
     * @notice Validates an operation without state changes (view function)
     * @param op The operation to validate
     * @return result True if the operation would be valid
     * @dev Used for operation preview and testing without consuming nonce.
     * Performs all validation checks except nonce increment.
     */
    function validateOpView(Op calldata op) public view returns (bool result) {
        // Extract and verify nonce from validation data
        _checkNonce(uint256(bytes32(op.validationData[:NONCE_OFFSET])));

        // Create message hash for signature verification
        bytes32 message = messageFromOp(op);

        // Verify signatures meet quorum requirements
        if (!isValidSignature(message, op.validationData[NONCE_OFFSET:])) {
            revert InvalidSignature();
        }

        // Validate the operation against whitelist and parameter rules
        result = _validateBaseOp(op.base);
    }

    /**
     * @notice Validates a batch of operations and increments the nonce if all are valid
     * @param batch The batch operation containing multiple operations to validate atomically
     * @return result True if all operations in the batch are valid and properly signed
     * @dev All operations in the batch share the same nonce and signature set.
     * If any operation fails validation, the entire batch is rejected.
     */
    function validateBatchedOp(BatchOp calldata batch) external onlyVault returns (bool result) {
        result = validateBatchedOpView(batch);
        // Increment nonce after successful batch validation
        nextNonce++;

        return true;
    }

    /**
     * @notice Validates a batch of operations without state changes (view function)
     * @param batch The batch operation to validate
     * @return True if all operations in the batch would be valid
     * @dev Used for batch operation preview and testing without consuming nonce.
     * Validates each operation in the batch against whitelist rules.
     */
    function validateBatchedOpView(BatchOp calldata batch) public view returns (bool) {
        // Extract and verify nonce from validation data
        _checkNonce(uint256(bytes32(batch.validationData[:NONCE_OFFSET])));

        // Create message hash for the entire batch
        bytes32 message = messageFromOps(batch.ops);

        // Verify signatures meet quorum requirements for the batch
        if (!isValidSignature(message, batch.validationData[NONCE_OFFSET:])) {
            revert InvalidSignature();
        }

        uint256 batchLength = batch.ops.length;

        // Validate each operation in the batch
        for (uint256 i = 0; i < batchLength; ++i) {
            if (!_validateBaseOp(batch.ops[i])) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Internal function to configure a whitelisted call during construction
     * @param call The call configuration containing target, permissions, allowances, and selectors
     * @dev Validates the configuration and sets up all necessary mappings for the call
     */
    function _whitelist(WhitelistedCall memory call) private {
        if (call.target == address(0)) revert ZeroAddress();
        if (call.permissions == 0) revert InvalidPermissions();

        uint256 callSelectorAndCheckerLength = call.selectorAndChecker.length;

        // If function calls are allowed, ensure at least one selector is whitelisted
        if ((call.permissions & bytes1(CALL_FUNCTIONS)) != 0 && callSelectorAndCheckerLength == 0) {
            revert InvalidPermissions();
        }

        // Set ETH allowance if specified
        if (call.maxAllowance > 0) {
            maxAllowance[call.target] = call.maxAllowance;
            emit TargetWhitelisted(call.target, call.maxAllowance);
        }

        // Set permission flags for the target
        whitelistedAddresses[call.target] = call.permissions;

        // Whitelist function selectors with their parameter validators
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
     * @notice Verifies that a set of signatures is valid for a message and meets quorum requirements
     * @param message The message hash that was signed by the signers
     * @param signatures Concatenated ECDSA signatures (65 bytes each: r(32) + s(32) + v(1))
     * @return True if signatures are valid and total weight meets or exceeds quorum
     * @dev Signature format: Each signature is 65 bytes with r, s, v components
     * @dev Prevents duplicate signers and validates each signature against known signers
     * @dev TODO: Consider implementing BLS signatures for better gas efficiency with many signers
     */
    function isValidSignature(bytes32 message, bytes memory signatures) public view returns (bool) {
        uint256 allSignaturesLength = signatures.length;

        // Ensure signature data length is valid (multiple of 65 bytes)
        if (allSignaturesLength % 65 != 0) {
            revert InvalidSignature();
        }

        uint256 sigCount = allSignaturesLength / 65;
        uint256 totalSigWeight = 0;
        address[] memory signersList = new address[](sigCount);

        // Process each 65-byte signature
        for (uint256 i = 0; i < sigCount; ++i) {
            uint256 offset = i * 65;

            // Extract ECDSA signature components using assembly for efficiency
            bytes32 r;
            bytes32 s;
            uint8 v;

            assembly {
                // Extract r (first 32 bytes of signature)
                r := mload(add(add(signatures, 32), offset))
                // Extract s (next 32 bytes of signature)
                s := mload(add(add(signatures, 64), offset))
                // Extract v (last byte of signature)
                v := byte(0, mload(add(add(signatures, 96), offset)))
            }

            // Normalize v value for ecrecover (must be 27 or 28)
            if (v < 27) {
                v += 27;
            }

            // Recover signer address from signature
            address signer = ecrecover(message, v, r, s);

            // Validate recovered address
            if (signer == address(0)) {
                revert InvalidSignature();
            }

            // Check if signer is authorized and get their weight
            uint256 weight = signers[signer];
            if (weight == 0) {
                revert InvalidSigner(signer);
            }

            // Prevent duplicate signers in the same signature set
            for (uint256 j = 0; j < i; j++) {
                if (signersList[j] == signer) {
                    revert DuplicateSigner(signer);
                }
            }

            // Record signer and accumulate weight
            signersList[i] = signer;
            totalSigWeight += weight;
        }

        // Verify total signature weight meets minimum quorum
        if (totalSigWeight < quorum) {
            revert QuorumNotMet(totalSigWeight, quorum);
        }

        return true;
    }

    /**
     * @dev Internal function to validate a base operation against whitelist rules
     * @param op The base operation containing target, value, and data
     * @return True if the operation passes all validation checks
     * @dev Performs comprehensive validation:
     * - Target address must be whitelisted
     * - ETH value must not exceed target's allowance
     * - Function calls must have whitelisted selectors
     * - Parameters must pass validation if a validator is configured
     */
    function _validateBaseOp(BaseOp calldata op) internal view returns (bool) {
        address target = op.target;
        uint256 value = op.value;

        // Check if target address is whitelisted
        uint8 authorization = uint8(whitelistedAddresses[target]);
        if (authorization == 0) revert TargetNotWhitelisted(target);

        uint256 dataLength = op.data.length;

        // Prevent meaningless no-op calls (no value, no data)
        if (value == 0 && dataLength == 0) {
            revert EmptyOperation();
        }

        // Validate ETH transfer permissions and limits
        if ((value > 0 && (authorization & SEND_ETH) == 0) || (value > maxAllowance[target])) {
            revert ExceedsAllowance(maxAllowance[target], value);
        }

        // Validate function call data
        if (dataLength > 0 && dataLength < 4) revert DataFieldTooShort();

        if (dataLength > 0 && (authorization & CALL_FUNCTIONS) == 0) {
            revert TargetNotWhitelisted(target);
        }

        // Validate function selector and parameters for function calls
        if (dataLength >= 4) {
            bytes4 selector = bytes4(op.data[:4]);
            address paramsValidator = whitelistedSelectors[target][selector];

            if (paramsValidator == address(0)) {
                revert SelectorNotWhitelisted(selector);
            }

            // Perform parameter validation if validator is configured and parameters exist
            if (paramsValidator != NO_PARAMS_CHECKS_ADDRESS && dataLength > 4) {
                bytes memory data = op.data[4:];
                IParameterValidator validator = IParameterValidator(paramsValidator);
                if (!validator.validateParameters(data)) {
                    revert ParameterValidationFailed();
                }
            }
        }

        return true;
    }

    /**
     * @notice Creates an Ethereum signed message hash from an array of base operations
     * @param ops Array of base operations to hash
     * @return The Ethereum signed message hash for signature verification
     * @dev Used for batch operation signature verification. Includes chain ID and sender
     * for additional security against cross-chain and cross-contract replay attacks.
     */
    function messageFromOps(BaseOp[] calldata ops) public view returns (bytes32) {
        bytes memory combinedData = new bytes(0);

        // Include chain ID and sender address for replay protection
        combinedData = abi.encodePacked(block.chainid, msg.sender);

        uint256 opsLength = ops.length;

        // Concatenate all operation data
        for (uint256 i = 0; i < opsLength; ++i) {
            combinedData = abi.encodePacked(combinedData, abi.encodePacked(ops[i].target, ops[i].value, ops[i].data));
        }

        // Return Ethereum signed message hash
        return keccak256(combinedData).toEthSignedMessageHash();
    }

    /**
     * @notice Creates an Ethereum signed message hash from a single operation
     * @param op The operation to hash including validation data
     * @return The Ethereum signed message hash for signature verification
     * @dev Includes nonce, chain ID, and sender for comprehensive replay protection
     */
    function messageFromOp(Op calldata op) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.chainid,
                msg.sender,
                bytes32(op.validationData[:NONCE_OFFSET]),
                op.base.target,
                op.base.value,
                op.base.data
            )
        ).toEthSignedMessageHash(); // nonce
    }

    /**
     * @dev Internal function to verify nonce matches expected value
     * @param nonce The nonce provided in the operation
     * @dev Prevents replay attacks by ensuring operations are processed sequentially
     */
    function _checkNonce(uint256 nonce) internal view {
        if (nonce != nextNonce) {
            revert InvalidNonce(nonce, nextNonce);
        }
    }

    /**
     * @notice Associates this validator with a vault address (one-time initialization)
     * @param _vault The vault address to associate with this validator
     * @param signatures Multi-signature authorization from current signers
     * @dev Can only be called once. Requires signatures meeting current quorum.
     * This binding ensures the validator can only be used by the designated vault.
     */
    function setVault(address _vault, bytes calldata signatures) external {
        if (vault != address(0)) revert VaultAlreadySet();
        if (_vault == address(0)) revert ZeroAddress();

        // Create message hash for vault binding authorization
        bytes32 messageHash = keccak256(abi.encodePacked("MuSigOpValidator_SET_VAULT", _vault)).toEthSignedMessageHash();

        // Verify signatures meet current quorum
        if (!isValidSignature(messageHash, signatures)) {
            revert InvalidSignature();
        }

        vault = _vault;
    }

    /**
     * @notice Updates a single signer's weight and optionally the quorum requirement
     * @param newSigner Signer configuration (address and new weight, 0 weight removes signer)
     * @param newQuorum New quorum requirement (must be > 0)
     * @param signatures Multi-signature authorization from current signers meeting current quorum
     * @dev Allows adding new signers, updating existing signer weights, or removing signers.
     * Quorum can be updated simultaneously. All changes require current quorum approval.
     * @dev Weight of 0 removes the signer from the active set
     */
    function updateSigner(Signer calldata newSigner, uint256 newQuorum, bytes calldata signatures) external {
        if (newQuorum == 0) revert("Quorum cannot be zero");

        // Create authorization message hash
        bytes32 messageHash = _hashSignersData(newSigner, newQuorum);

        // Verify signatures meet current quorum
        if (!isValidSignature(messageHash, signatures)) {
            revert InvalidSignature();
        }

        uint256 currentSignerWeight = signers[newSigner.signer];

        if (currentSignerWeight == 0) {
            // Adding new signer
            if (newSigner.weight == 0) revert InvalidSignerWeight();
            signers[newSigner.signer] = newSigner.weight;
            totalWeight += newSigner.weight;
        } else {
            // Updating or removing existing signer
            if (newSigner.weight == 0) {
                // Removing signer
                totalWeight -= currentSignerWeight;
                delete signers[newSigner.signer];
            } else {
                // Updating signer weight
                totalWeight = totalWeight - currentSignerWeight + newSigner.weight;
                signers[newSigner.signer] = newSigner.weight;
            }
        }

        // Update quorum
        quorum = newQuorum;

        emit SignersUpdated(newSigner.signer, newSigner.weight, newQuorum, totalWeight);
    }

    /**
     * @notice Updates the quorum requirement for operation approval
     * @param newQuorum New quorum requirement (must be > 0)
     * @param signatures Multi-signature authorization from current signers meeting current quorum
     * @dev Allows changing the minimum signature weight required to approve operations.
     * Requires signatures from current signers meeting the existing quorum.
     */
    function updateQuorum(uint256 newQuorum, bytes calldata signatures) external {
        if (newQuorum == 0) revert("Quorum cannot be zero");

        // Create authorization message hash
        bytes32 messageHash = _newQuorumHash(newQuorum);

        // Verify signatures meet current quorum
        if (!isValidSignature(messageHash, signatures)) {
            revert InvalidSignature();
        }

        // Update quorum
        quorum = newQuorum;

        emit QuorumUpdated(newQuorum);
    }

    /**
     * @dev Internal helper to create message hash for signer update authorization
     * @param signer Signer configuration being updated
     * @param newQuorum New quorum requirement
     * @return Message hash for signature verification
     */
    function _hashSignersData(Signer calldata signer, uint256 newQuorum) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("MuSigOpValidator_UPDATE_SIGNERS", signer.signer, signer.weight, newQuorum))
            .toEthSignedMessageHash();
    }

    /**
     * @dev Internal helper to create message hash for quorum update authorization
     * @param newQuorum New quorum requirement
     * @return Message hash for signature verification
     */
    function _newQuorumHash(uint256 newQuorum) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("MuSigOpValidator_UPDATE_QUORUM", newQuorum)).toEthSignedMessageHash();
    }
}
