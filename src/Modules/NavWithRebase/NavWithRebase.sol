// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;
import "forge-std/Test.sol";

import {INav} from "../../interfaces/modules/INav.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LobsterVault} from "../../Vault/Vault.sol";

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
    IERC20 private vaultAsset;

    address public vault;
    /// @notice The total assets of the vault (without the vault's assets balance)
    uint256 public totalAssets_;
    uint256 public lastRebaseTimestamp;
    uint256 public rebaseValidUntil;

    mapping(address => bool) public rebasers;
    /// @notice Mapping to track if a user has accepted the no rebase condition: address => approval deadline
    mapping(address => uint256) public acceptNoRebase;

    error AlreadyInitialized();
    error InvalidSignature();

    constructor(
        address initialOwner,
        uint256 initialTotalAssets
    ) Ownable(initialOwner) {
        lastRebaseTimestamp = block.timestamp;
        totalAssets_ = initialTotalAssets;
    }

    function initialize(address _vault) external onlyOwner {
        require(vault == address(0), AlreadyInitialized());
        vault = _vault;
        vaultAsset = IERC20(LobsterVault(vault).asset());
    }

    /**
     * @inheritdoc INav
     * @dev This function uses a manual rebase mechanism to calculate the total assets.
     * @dev If the rebase is not valid, it returns the vault's balance of the asset
     */
    function totalAssets() external view returns (uint256) {
        if (block.timestamp <= rebaseValidUntil) {
            return totalAssets_ + vaultAsset.balanceOf(vault);
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
        require(
            validUntil >= block.timestamp && validUntil >= rebaseValidUntil,
            "NavWithRebase: Invalid validUntil"
        );
        console.log("validUntil", validUntil);
        // Ensure the signature is valid
        address signer = _validateRebaseSignature(
            validationData,
            newTotalAssets,
            validUntil
        );
        console.log("signer", signer);

        require(rebasers[signer], InvalidSignature());

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
        require(validationData.length == 65, InvalidSignature());

        // Extract the signature components
        uint8 v;
        bytes32 r;
        bytes32 s;
        assembly {
            let dataOffset := validationData.offset
            v := byte(0, calldataload(dataOffset))
            r := calldataload(add(dataOffset, 1))
            s := calldataload(add(dataOffset, 33))
        }

        console.log("v", v);
        console.log("r", uint256(r));
        console.log("s", uint256(s));

        // Ensure the signature is valid
        address signer = ecrecover(
           getMessage(newTotalAssets, validUntil),
            v,
            r,
            s
        );

        require(signer != address(0), InvalidSignature());
        return signer;
    }

    function getMessage(
        uint256 newTotalAssets,
        uint256 validUntil
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    address(this),
                    block.chainid,
                    newTotalAssets,
                    validUntil
                )
            );
    }

    // todo: allow users to acceptNoRebase
}
