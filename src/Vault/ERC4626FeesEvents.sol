// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct PendingFeeUpdate {
    uint256 value;
    uint256 activationTimestamp;
}

interface IERC4626FeesEvents {
    event NewPendingEntryFeeUpdate(
        uint256 newFeeBasisPoints,
        uint256 activationTimestamp
    );
    event NewPendingExitFeeUpdate(
        uint256 newFeeBasisPoints,
        uint256 activationTimestamp
    );
    event NewPendingManagementFeeUpdate(
        uint256 newFeeBasisPoints,
        uint256 activationTimestamp
    );
    event NewPendingPerformanceFeeUpdate(
        uint256 newFeeBasisPoints,
        uint256 activationTimestamp
    );
    event EntryFeeEnforced(uint256 newFeeBasisPoints);
    event ExitFeeEnforced(uint256 newFeeBasisPoints);
    event ManagementFeeEnforced(uint256 newFeeBasisPoints);
    event PerformanceFeeEnforced(uint256 newFeeBasisPoints);

    /**
     * @dev Emitted when fees are collected
     */
    event FeeCollected(
        uint256 totalFees,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 entryFee,
        uint256 exitFee,
        uint256 timestamp
    );

    /**
     * @dev Emitted when fee collector is updated
     */
    event FeeCollectorUpdated(address feeCollector);

        // Error definitions
    error ActivationTimestampNotReached(
        uint256 currentTimestamp,
        uint256 activationTimestamp
    );
    error NoPendingFeeUpdate();
    error InvalidFee();
    error InsufficientAssetsForFees();
}
