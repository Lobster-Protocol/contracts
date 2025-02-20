// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Op} from "../interfaces/IValidator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

bytes1 constant DEPOSIT_OPERATION_BYTE = 0x00;
bytes1 constant WITHDRAW_OPERATION_BYTE = 0x01;

// Base contract that will be inherited by Vault
abstract contract LobsterOpValidator {
    using Math for uint256;

    uint256 public valueOutsideVault = 0; // value owned by the vault in third party chains/protocols
    uint256 public rebaseExpiresAt = 0;
    address public lobsterAlgorithm;

    // addresses allowed to rebase the vault
    mapping(address => bool) public rebaseOperators;

    // Mapping to store valid target addresses
    mapping(address => bool) public validTargets;
    // Mapping to store valid function selectors for each target
    mapping(address => mapping(bytes4 => bool)) public validSelectors;

    error OpNotApproved();
    error InvalidVault();

    event Executed(address indexed target, uint256 value, bytes data);

    constructor(bytes memory validTargetsAndSelectorsData) {
        if (validTargetsAndSelectorsData.length > 0) {
            (address[] memory targets, bytes4[][] memory selectors) = abi
                .decode(validTargetsAndSelectorsData, (address[], bytes4[][]));

            for (uint256 i = 0; i < targets.length; i++) {
                validTargets[targets[i]] = true;
                for (uint256 j = 0; j < selectors[i].length; j++) {
                    validSelectors[targets[i]][selectors[i][j]] = true;
                }
            }
        }
    }

    // ensure msg.sender is the algorithm
    modifier onlySelfOrAlgorithm() {
        require(
            msg.sender == lobsterAlgorithm || msg.sender == address(this),
            "Vault: only algorithm"
        );
        _;
    }

    /* ------------------LOBSTER ALGO FUNCTIONS FOR CUSTOM CALLS------------------ */

    function executeOp(Op calldata op) external onlySelfOrAlgorithm {
        if (!validateOp(op)) {
            revert OpNotApproved();
        }
        _call(op);
    }

    function executeOpBatch(Op[] calldata ops) external onlySelfOrAlgorithm {
        if (!validateBatchedOp(ops)) {
            revert OpNotApproved();
        }

        uint256 length = ops.length;
        for (uint256 i = 0; i < length; ) {
            _call(ops[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _call(Op calldata op) private {
        (bool success, bytes memory result) = op.target.call{value: op.value}(
            op.data
        );

        assembly {
            if iszero(success) {
                revert(add(result, 32), mload(result))
            }
        }

        emit Executed(op.target, op.value, op.data);
    }

    /* Approve custom operation */
    function validateOp(Op calldata op) public view returns (bool) {
        require(validTargets[op.target], "Invalid target");
        require(validSelectors[op.target][bytes4(op.data)], "Invalid selector");
        return true;
    }

    /* Approve custom operations */
    function validateBatchedOp(Op[] calldata ops) public view returns (bool) {
        for (uint256 i = 0; i < ops.length; i++) {
            require(validTargets[ops[i].target], "Invalid target");
            require(
                validSelectors[ops[i].target][bytes4(ops[i].data)],
                "Invalid selector"
            );
        }
        return true;
    }

    /* ---------------------------------------------------- */

    function rebase(bytes calldata rebaseData) external {
        _verifyAndRebase(rebaseData);
    }

    /**
     * @notice Verify the rebase signature and update the rebase value before redeeming shares
     *
     * @dev This function is called before mint/deposit/withdraw/redeem shares to verify the rebase signature and update the rebase value
     * rebaseData is expected to be:
     * 1 byte - 0x00 if deposit/mint 0x01 if withdraw/redeem
     * 32 bytes - the minimum assets to be withdrawn (used by redeem / withdraw functions)
     * 20 bytes - vault address
     * abiEncoded: _valueOutsideVault, _rebaseExpiresAt, withdrawOperations, signature
     * _valueOutsideVault - the ETH value outside the chain
     * _rebaseExpiresAt - the block number at which the rebase expires
     * withdrawOperations - the operations to be executed to withdraw the assets (only for withdraw/redeem. 0x for deposit/mint)
     * signature - the signature of the rebase data
     *
     * @param rebaseData - the rebase data to be validated
     */
    function _verifyAndRebase(bytes calldata rebaseData) internal {
        bytes1 operation = rebaseData[0];
        address vault = address(bytes20(rebaseData[33:53]));
        if (vault != address(this)) {
            revert InvalidVault();
        }

        (
            uint256 _valueOutsideVault,
            uint256 _rebaseExpiresAt,
            bytes memory withdrawOperations,
            bytes memory signature
        ) = abi.decode(rebaseData[53:], (uint256, uint256, bytes, bytes));

        require(
            _rebaseExpiresAt > block.number &&
                _rebaseExpiresAt > rebaseExpiresAt,
            "Rebase expired"
        );

        bytes32 messageHash = keccak256(
            abi.encode(
                _valueOutsideVault,
                _rebaseExpiresAt,
                withdrawOperations,
                block.chainid,
                vault
            )
        );

        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            messageHash
        );

        address signer = ECDSA.recover(ethSignedMessageHash, signature);
        require(rebaseOperators[signer], "Invalid signature");

        // update rebase values
        valueOutsideVault = _valueOutsideVault;
        rebaseExpiresAt = _rebaseExpiresAt;

        // if needed, execute withdraw operations
        if (
            withdrawOperations.length > 0 &&
            operation == WITHDRAW_OPERATION_BYTE
        ) {
            (Op[] memory ops, uint256 newValueOutsideChain) = abi.decode(
                withdrawOperations,
                (Op[], uint256)
            );
            (bool success, bytes memory result) = address(this).call{value: 0}(
                abi.encodeWithSelector(this.executeOpBatch.selector, ops)
            );

            // revert the withdraw if the operations failed
            assembly {
                if iszero(success) {
                    revert(add(result, 32), mload(result))
                }
            }

            // update the value outside the vault
            valueOutsideVault = newValueOutsideChain;
        }
    }
}
