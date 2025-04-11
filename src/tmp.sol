// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Interface for parameter validators
interface IParameterValidator {
    function validateParameters(
        bytes calldata parameters
    ) external view returns (bool);
}

/**
 * @title WhitelistedProxy
 * @notice A contract that can execute transactions to whitelisted target contracts
 * with function selector and parameter validation
 */
contract WhitelistedProxy {
    address public owner;

    // Mapping to store whitelisted target addresses
    mapping(address => bool) public whitelistedTargets;

    // Mapping to store max ETH allowance per target
    mapping(address => uint256) public maxAllowance;

    // Mapping to store whitelisted function selectors per target
    mapping(address => mapping(bytes4 => bool)) public whitelistedSelectors;

    // Mapping to store custom parameter validators per target and function selector
    mapping(address => mapping(bytes4 => address)) public parameterValidators;

    // Events
    event TargetWhitelisted(address indexed target, uint256 allowance);
    event TargetRemoved(address indexed target);
    event SelectorWhitelisted(address indexed target, bytes4 indexed selector);
    event SelectorRemoved(address indexed target, bytes4 indexed selector);
    event ValidatorSet(
        address indexed target,
        bytes4 indexed selector,
        address validator
    );
    event TransactionExecuted(
        address indexed target,
        bytes4 indexed selector,
        uint256 value,
        bool success
    );

    // Errors
    error NotOwner();
    error TargetNotWhitelisted();
    error FunctionSelectorNotWhitelisted();
    error ExceedsAllowance();
    error ParameterValidationFailed();
    error ExecutionFailed();

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @notice Change the owner of the contract
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /**
     * @notice Add a target address to the whitelist with a max ETH allowance
     * @param target Address of the target contract
     * @param allowance Maximum ETH amount that can be sent to this target
     */
    function whitelistTarget(
        address target,
        uint256 allowance
    ) external onlyOwner {
        whitelistedTargets[target] = true;
        maxAllowance[target] = allowance;
        emit TargetWhitelisted(target, allowance);
    }

    /**
     * @notice Remove a target address from the whitelist
     * @param target Address of the target contract to remove
     */
    function removeTarget(address target) external onlyOwner {
        whitelistedTargets[target] = false;
        emit TargetRemoved(target);
    }

    /**
     * @notice Add a function selector to the whitelist for a specific target
     * @param target Address of the target contract
     * @param selector Function selector (first 4 bytes of the function signature)
     */
    function whitelistSelector(
        address target,
        bytes4 selector
    ) external onlyOwner {
        whitelistedSelectors[target][selector] = true;
        emit SelectorWhitelisted(target, selector);
    }

    /**
     * @notice Remove a function selector from the whitelist for a specific target
     * @param target Address of the target contract
     * @param selector Function selector to remove
     */
    function removeSelector(
        address target,
        bytes4 selector
    ) external onlyOwner {
        whitelistedSelectors[target][selector] = false;
        emit SelectorRemoved(target, selector);
    }

    /**
     * @notice Set a custom parameter validator for a specific target and function selector
     * @param target Address of the target contract
     * @param selector Function selector
     * @param validator Address of the validator contract implementing IParameterValidator
     */
    function setParameterValidator(
        address target,
        bytes4 selector,
        address validator
    ) external onlyOwner {
        parameterValidators[target][selector] = validator;
        emit ValidatorSet(target, selector, validator);
    }

    /**
     * @notice Execute a transaction to a whitelisted target with a whitelisted function
     * @param target Address of the target contract
     * @param value ETH amount to send with the transaction
     * @param data Function call data (including selector and parameters)
     * @return success Whether the execution was successful
     * @return returnData Data returned by the executed function
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bool success, bytes memory returnData) {
        // Check if target is whitelisted
        if (!whitelistedTargets[target]) revert TargetNotWhitelisted();

        // Check if value is within allowance
        if (value > maxAllowance[target]) revert ExceedsAllowance();

        // Extract function selector from data
        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }

        // Check if function selector is whitelisted
        if (!whitelistedSelectors[target][selector])
            revert FunctionSelectorNotWhitelisted();

        // Check parameter validation if a validator is set
        address validator = parameterValidators[target][selector];
        if (validator != address(0)) {
            // Extract parameters (skip the first 4 bytes which is the selector)
            bytes calldata parameters = data[4:];

            // Call the validator to check parameters
            bool isValid = IParameterValidator(validator).validateParameters(
                parameters
            );
            if (!isValid) revert ParameterValidationFailed();
        }

        // Execute the transaction
        (success, returnData) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed();

        emit TransactionExecuted(target, selector, value, success);

        return (success, returnData);
    }

    // Allow the contract to receive ETH
    receive() external payable {}
}

/**
 * @title Example Parameter Validator
 * @notice Example of a parameter validator contract
 */
contract ExampleValidator is IParameterValidator {
    /**
     * @notice Validate parameters for a specific function
     * @param parameters The encoded parameters (without the function selector)
     * @return Whether the parameters are valid
     */
    function validateParameters(
        bytes calldata parameters
    ) external pure override returns (bool) {
        // Example: Check if a uint256 parameter is within a certain range
        if (parameters.length == 32) {
            // uint256 is 32 bytes
            uint256 param;
            assembly {
                param := calldataload(parameters.offset)
            }

            // Example validation: check if param is less than 1000
            return param < 1000;
        }

        return false;
    }
}
