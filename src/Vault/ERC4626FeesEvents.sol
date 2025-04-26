// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

/**
 * @title ERC4626 Fees Events Interface
 * @author Lobster
 * @notice Interface defining events and errors related to fee operations in ERC4626 fee vaults
 * @dev This contract is used as a base for ERC4626 vault implementations that include fee mechanisms
 */

/**
 * @notice Structure representing a pending fee update
 * @param value The new fee value in basis points
 * @param activationTimestamp The timestamp when the new fee can be activated
 * @dev Used in the timelock mechanism for fee changes
 */
struct PendingFeeUpdate {
    uint16 value;
    uint256 activationTimestamp;
}

/**
 * @notice Interface containing all events and errors for ERC4626 fee vaults
 * @dev This interface should be implemented by contracts that manage fee operations
 */
interface IERC4626FeesEvents {
    /**
     * @notice Emitted when a new entry fee update is scheduled
     * @param newFeeBasisPoints The proposed new entry fee in basis points
     * @param activationTimestamp The timestamp when the new fee can be activated
     */
    event NewPendingEntryFeeUpdate(uint256 newFeeBasisPoints, uint256 activationTimestamp);

    /**
     * @notice Emitted when a new exit fee update is scheduled
     * @param newFeeBasisPoints The proposed new exit fee in basis points
     * @param activationTimestamp The timestamp when the new fee can be activated
     */
    event NewPendingExitFeeUpdate(uint256 newFeeBasisPoints, uint256 activationTimestamp);

    /**
     * @notice Emitted when a new management fee update is scheduled
     * @param newFeeBasisPoints The proposed new management fee in basis points
     * @param activationTimestamp The timestamp when the new fee can be activated
     */
    event NewPendingManagementFeeUpdate(uint256 newFeeBasisPoints, uint256 activationTimestamp);

    /**
     * @notice Emitted when a new entry fee is enforced
     * @param newFeeBasisPoints The newly enforced entry fee in basis points
     */
    event EntryFeeEnforced(uint256 newFeeBasisPoints);

    /**
     * @notice Emitted when a new exit fee is enforced
     * @param newFeeBasisPoints The newly enforced exit fee in basis points
     */
    event ExitFeeEnforced(uint256 newFeeBasisPoints);

    /**
     * @notice Emitted when a new management fee is enforced
     * @param newFeeBasisPoints The newly enforced management fee in basis points
     */
    event ManagementFeeEnforced(uint256 newFeeBasisPoints);

    /**
     * @notice Emitted when fees are collected
     * @param totalFees The total amount of fees collected in shares
     * @param managementFee The portion of fees from management fees in shares
     * @param entryFee The portion of fees from entry fees in shares
     * @param exitFee The portion of fees from exit fees in shares
     * @param timestamp The timestamp when fees were collected
     */
    event FeeCollected(uint256 totalFees, uint256 managementFee, uint256 entryFee, uint256 exitFee, uint256 timestamp);

    /**
     * @notice Emitted when the fee collector address is updated
     * @param feeCollector The new fee collector address
     */
    event FeeCollectorUpdated(address feeCollector);

    /**
     * @notice Thrown when attempting to enforce a fee update before its activation timestamp
     * @param currentTimestamp The current block timestamp
     * @param activationTimestamp The required activation timestamp for the fee update
     */
    error ActivationTimestampNotReached(uint256 currentTimestamp, uint256 activationTimestamp);

    /**
     * @notice Thrown when attempting to enforce a fee update when none is pending
     */
    error NoPendingFeeUpdate();

    /**
     * @notice Thrown when attempting to set a fee that exceeds the maximum allowed value
     */
    error InvalidFee();

    /**
     * @notice Thrown when there are not enough assets in the vault to cover fee collection
     */
    error InsufficientAssetsForFees();
}
