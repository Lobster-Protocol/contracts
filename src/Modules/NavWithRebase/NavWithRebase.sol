// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {INav} from "../../interfaces/modules/INav.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LobsterVault} from "../../Vault/Vault.sol";
import {BatchOp} from "../../interfaces/modules/IOpValidatorModule.sol";

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
    /// @notice The vault's primary asset token
    IERC20 private vaultAsset;

    /// @notice Address of the vault contract this module serves
    address public vault;
    
    /// @notice The total assets of the vault (without the vault's assets balance)
    /// @dev This represents assets that are deployed externally and not held directly in the vault
    uint256 public totalAssets_;
    
    /// @notice Timestamp of the last successful rebase operation
    uint256 public lastRebaseTimestamp;
    
    /// @notice Timestamp until which the current rebase is considered valid
    /// @dev After this timestamp, totalAssets() falls back to vault's direct balance
    uint256 public rebaseValidUntil;

    /// @notice Mapping of addresses authorized to sign rebase operations
    /// @dev Only addresses with true value can provide valid rebase signatures
    mapping(address => bool) public rebasers;
    
    /// @notice Mapping to track if a user has accepted the no rebase condition: address => approval deadline
    /// @dev When set, allows users to bypass rebase calculations for withdrawals
    mapping(address => uint256) public acceptNoRebase;

    /// @notice Thrown when trying to initialize an already initialized contract
    error AlreadyInitialized();
    
    /// @notice Thrown when a rebase signature is invalid or from unauthorized signer
    error InvalidSignature();

    /**
     * @notice Constructor initializes the contract with owner and initial total assets
     * @param initialOwner Address that will own this contract
     * @param initialTotalAssets Starting value for total external assets
     */
    constructor(address initialOwner, uint256 initialTotalAssets) Ownable(initialOwner) {
        lastRebaseTimestamp = block.timestamp;
        totalAssets_ = initialTotalAssets;
    }

    /**
     * @notice Initializes the contract with vault address and sets up vault asset
     * @param _vault Address of the LobsterVault contract this module will serve
     * @dev Can only be called once by the owner
     */
    function initialize(address _vault) external onlyOwner {
        require(vault == address(0), AlreadyInitialized());
        vault = _vault;
        vaultAsset = IERC20(LobsterVault(vault).asset());
    }

    /**
     * @inheritdoc INav
     * @notice Returns the total assets under management by the vault
     * @dev This function uses a manual rebase mechanism to calculate the total assets.
     *      If the rebase is valid (current time <= rebaseValidUntil), returns external assets + vault balance.
     *      If the rebase is expired, returns only the vault's direct token balance.
     * @return Total assets managed by the vault
     */
    function totalAssets() external view returns (uint256) {
        if (block.timestamp <= rebaseValidUntil) {
            return totalAssets_ + vaultAsset.balanceOf(vault);
        } else {
            return vaultAsset.balanceOf(vault);
        }
    }

    /**
     * @notice Returns only the assets held locally in the vault contract
     * @dev This excludes any external assets and only shows the vault's direct token balance
     * @return The vault's direct balance of the asset token
     */
    function totalLocalAssets() external view returns (uint256) {
        return vaultAsset.balanceOf(vault);
    }

    /**
     * @notice Sets or removes rebaser authorization for an address
     * @param rebaser Address to authorize or deauthorize
     * @param isRebaser True to authorize, false to deauthorize
     * @dev Only authorized rebasers can sign valid rebase operations
     */
    function setRebaser(address rebaser, bool isRebaser) external onlyOwner {
        rebasers[rebaser] = isRebaser;
    }

    /**
     * @notice Updates the total assets value with a signed rebase operation
     * @param newTotalAssets New value for external total assets
     * @param validUntil Timestamp until which this rebase remains valid
     * @param operationData Optional encoded BatchOp to execute during rebase (for unlocking assets)
     * @param validationData 65-byte signature validating this rebase operation
     * @dev The signature must be from an authorized rebaser and cover all parameters
     * @dev If operationData is provided, executes the operations on the vault
     */
    function rebase(
        uint256 newTotalAssets,
        uint256 validUntil,
        bytes calldata operationData,
        bytes calldata validationData
    )
        external
    {
        require(validUntil >= block.timestamp && validUntil >= rebaseValidUntil, "NavWithRebase: Invalid validUntil");
        
        // Ensure the signature is valid and from authorized rebaser
        address signer = _validateRebaseSignature(validationData, newTotalAssets, validUntil, operationData);
        require(rebasers[signer], InvalidSignature());

        // Update state
        totalAssets_ = newTotalAssets;
        lastRebaseTimestamp = block.timestamp;
        rebaseValidUntil = validUntil;

        // Execute any provided operations (e.g., to unlock assets)
        if (operationData.length > 0) {
            BatchOp memory operations = abi.decode(operationData, (BatchOp));
            LobsterVault(vault).executeOpBatch(operations);
        }
    }

    /**
     * @notice Validates the signature for a rebase operation
     * @param validationData 65-byte signature data (v + r + s)
     * @param newTotalAssets New total assets value being signed
     * @param validUntil Validity timestamp being signed
     * @param operationData Operation data being signed
     * @return signer Address that created the signature
     */
    function _validateRebaseSignature(
        bytes calldata validationData,
        uint256 newTotalAssets,
        uint256 validUntil,
        bytes calldata operationData
    )
        internal
        view
        returns (address)
    {
        // Ensure signature is 65 bytes long (v + r + s)
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

        // Recover signer from signature and message hash
        address signer = ecrecover(getMessage(newTotalAssets, validUntil, operationData), v, r, s);
        require(signer != address(0), InvalidSignature());
        
        return signer;
    }

    /**
     * @notice Generates the message hash for signature verification
     * @param newTotalAssets New total assets value
     * @param validUntil Validity timestamp
     * @param operationData Operation data to be executed
     * @return Message hash
     * @dev Creates a unique message hash that includes contract address, chain ID, and all parameters
     */
    function getMessage(
        uint256 newTotalAssets,
        uint256 validUntil,
        bytes calldata operationData
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                address(this),
                block.chainid,
                newTotalAssets,
                validUntil,
                operationData
            )
        );
    }

    // todo: allow users to acceptNoRebase
}