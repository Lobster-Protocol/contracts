// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Op} from "../interfaces/IValidator.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// Base contract that will be inherited by Vault
contract LobsterOpValidator {
    uint256 public valueOutsideChain = 0;
    uint256 public rebaseExpiresAt = 0;
    address public lobsterAlgorithm;
    // addresses allowed to rebase the vault
    mapping(address => bool) public rebaseOperators;

    // Mapping to store valid target addresses
    mapping(address => bool) public validTargets;
    // Mapping to store valid function selectors for each target
    mapping(address => mapping(bytes4 => bool)) public validSelectors;

    error OpNotApproved();

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
    modifier onlyAlgorithm() {
        require(msg.sender == lobsterAlgorithm, "Vault: only algorithm");
        _;
    }

    /* ------------------LOBSTER ALGO FUNCTIONS FOR CUSTOM CALLS------------------ */

    function executeOp(Op calldata op) external onlyAlgorithm {
        if (!validateOp(op)) {
            revert OpNotApproved();
        }
        _call(op);
    }

    function executeOpBatch(Op[] calldata ops) external onlyAlgorithm {
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

    function _verifyAndRebase(bytes calldata rebaseData) internal {
        address vault = address(bytes20(rebaseData[:20]));
        (
            uint256 _valueOutsideChain,
            uint256 _rebaseExpiresAt,
            bytes memory signature
        ) = abi.decode(rebaseData[20:], (uint256, uint256, bytes));

        require(
            _rebaseExpiresAt > block.number &&
                _rebaseExpiresAt > rebaseExpiresAt,
            "Rebase expired"
        );

        bytes32 messageHash = keccak256(
            abi.encode(
                _valueOutsideChain,
                _rebaseExpiresAt,
                block.chainid,
                vault
            )
        );
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            messageHash
        );
        address signer = ECDSA.recover(ethSignedMessageHash, signature);
        require(rebaseOperators[signer], "Invalid signature");

        valueOutsideChain = _valueOutsideChain;
        rebaseExpiresAt = _rebaseExpiresAt;
    }
}
