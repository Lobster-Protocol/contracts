// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {INav} from "../../interfaces/modules/INav.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title NavWithRebase
 * @author Lobster
 * @notice This contract is a module for the vault that allows for rebasing of the total assets.
 * It is used to calculate the total assets of the vault using a manual rebase mechanism.
 * If the rebase is not valid, it returns the vault's balance of the asset thus allowing users
 * to withdraw using this balance as a base but occulting any other potential assets. To
 * ignore the rebase, user need to call the acceptNoRebase function (works for 1 withdrawal then needs to be re-activated).
 */
contract NavWithRebase is INav, Ownable {
    IERC20 private immutable vaultAsset;

    address public immutable vault;
    /// @notice The total assets of the vault (without the vault's assets balance)
    uint256 public totalAssets_;
    uint256 public lastRebaseTimestamp;
    uint256 public rebaseValidUntil;

    mapping(address => bool) public rebasers;
    /// @notice Mapping to track if a user has accepted the no rebase condition: address => approval deadline
    mapping(address => uint256) public acceptNoRebase;

    constructor(
        address initialOwner,
        address vaultAddress,
        uint256 initialTotalAssets
    ) Ownable(initialOwner) {
        lastRebaseTimestamp = block.timestamp;
        vault = vaultAddress;
        totalAssets_ = initialTotalAssets;
    }

    /**
     * @inheritdoc INav
     * @dev This function uses a manual rebase mechanism to calculate the total assets.
     * @dev If the rebase is not valid, it returns the vault's balance of the asset
     */
    function totalAssets() external view returns (uint256) {
        if (block.timestamp > rebaseValidUntil) {
            return totalAssets_;
        } else {
            return vaultAsset.balanceOf(vault);
        }
    }

    function totalLocalAssets() external view returns (uint256) {
        return vaultAsset.balanceOf(vault);
    }

    function setRebaser(address rebaser, bool isRebaser) external onlyOwner {
        rebasers[rebaser] = isRebaser;
    }

    function rebase(
        uint256 newTotalAssets,
        uint256 validUntil,
        bytes calldata validationData
    ) external {
        require(validUntil >= block.timestamp && validUntil >= rebaseValidUntil, "NavWithRebase: Invalid validUntil");

        // Ensure the signature is valid
        address signer = _validateRebaseSignature(
            validationData,
            newTotalAssets,
            validUntil
        );

        require(rebasers[signer], "NavWithRebase: Not a valid rebaser");

        totalAssets_ = newTotalAssets;
        lastRebaseTimestamp = block.timestamp;
        rebaseValidUntil = validUntil;
    }

    function _validateRebaseSignature(
        bytes calldata validationData,
        uint256 newTotalAssets,
        uint256 validUntil
    ) internal view returns (address) {
        // Ensure signature is 65 bytes long
        require(validationData.length == 65, "Invalid signature length");

        // Extract the signature components
        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            let dataOffset := validationData.offset
            calldatacopy(0x0, dataOffset, 0x60) // Copy 96 bytes (r, s, v) to memory starting at 0x0
            r := mload(0x0)
            s := mload(0x20)
            v := byte(0, mload(0x40))
        }

        // Ensure the signature is valid
        address signer = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    getMessage(newTotalAssets, validUntil)
                )
            ),
            v,
            r,
            s
        );

        require(signer != address(0), "Invalid signature");
        return signer;
    }

    function getMessage(
        uint256 newTotalAssets,
        uint256 validUntil
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    address(this),
                    block.chainid,
                    newTotalAssets,
                    validUntil
                )
            );
    }

    // todo: allow users to acceptNoRebase
}
