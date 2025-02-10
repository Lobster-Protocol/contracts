// SPDX-License-Identifier: MIT
// derived from https://docs.openzeppelin.com/contracts/5.x/erc4626
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626FeesEvents, PendingFeeUpdate} from "./ERC4626FeesEvents.sol";

/// @dev ERC-4626 vault with entry/exit fees expressed in https://en.wikipedia.org/wiki/Basis_point[basis point (bp)].
///
/// NOTE: The contract charges fees in terms of assets, not shares. This means that the fees are calculated based on the
/// amount of assets that are being deposited or withdrawn, and not based on the amount of shares that are being minted or
/// redeemed. This is an opinionated design decision that should be taken into account when integrating this contract.
abstract contract ERC4626Fees is IERC4626FeesEvents, ERC4626, Ownable2Step {
    using Math for uint256;
    // todo: add a function to know the maximal value to input in previewWithdraw to unlock all the assets (with the fee).
    // This value should be the one used in redeem/withdraw to unlock all the assets.
    uint256 private constant _BASIS_POINT_SCALE = 1e4;

    uint256 public constant FEE_UPDATE_DELAY = 2 weeks;
    uint256 public constant MAX_FEE = 200; // 2%

    uint256 public lastManagementFeeCollection;
    uint256 public entryFeeBasisPoints = 0;
    uint256 public exitFeeBasisPoints = 0;
    uint256 public managementFeeBasisPoints = 0; // annualized fee
    PendingFeeUpdate public pendingEntryFeeUpdate;
    PendingFeeUpdate public pendingExitFeeUpdate;
    PendingFeeUpdate public pendingManagementFeeUpdate;

    address public entryFeeCollector;
    address public exitFeeCollector;
    address public managementFeeCollector;

    constructor(address entryFeeCollector_, address exitFeeCollector_, address managementFeeCollector_) {
        entryFeeCollector = entryFeeCollector_;
        exitFeeCollector = exitFeeCollector_;
        managementFeeCollector = managementFeeCollector_;
    }

    // === Overrides ===

    /// @dev Preview taking an entry fee on deposit. See {IERC4626-previewDeposit}.
    function previewDeposit(
        uint256 assets
    ) public view virtual override returns (uint256) {
        uint256 fee = _feeOnTotal(assets, entryFeeBasisPoints);
        return super.previewDeposit(assets - fee);
    }

    /// @dev Preview adding an entry fee on mint. See {IERC4626-previewMint}.
    function previewMint(
        uint256 shares
    ) public view virtual override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + _feeOnRaw(assets, entryFeeBasisPoints);
    }

    /// @dev Preview adding an exit fee on withdraw. See {IERC4626-previewWithdraw}.
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, exitFeeBasisPoints);
        return super.previewWithdraw(assets + fee);
    }

    /// @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, exitFeeBasisPoints);
    }

    /// @dev Send entry fee to {entryFeeCollector}. See {IERC4626-_deposit}.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        // first collect management fee
        _collectManagementFees();

        uint256 fee = _feeOnTotal(assets, entryFeeBasisPoints);
        address feeRecipient = entryFeeCollector;

        super._deposit(caller, receiver, assets, shares);

        if (fee > 0 && feeRecipient != address(this)) {
            SafeERC20.safeTransfer(IERC20(asset()), feeRecipient, fee);
        }
    }

    /// @dev Send exit fee to {exitFeeCollector}. See {IERC4626-_deposit}.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        // first collect management fee
        _collectManagementFees();

        uint256 fee = _feeOnRaw(assets, exitFeeBasisPoints);
        address feeRecipient = exitFeeCollector;

        super._withdraw(caller, receiver, owner, assets, shares);

        if (fee > 0 && feeRecipient != address(this)) {
            SafeERC20.safeTransfer(IERC20(asset()), feeRecipient, fee);
        }
    }

    // === Fee configuration ===

    function setEntryFee(
        uint256 feeBasisPoints
    ) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE) revert InvalidFee();

        pendingEntryFeeUpdate = PendingFeeUpdate({
            value: feeBasisPoints,
            activationTimestamp: block.timestamp + FEE_UPDATE_DELAY
        });

        emit NewPendingEntryFeeUpdate(
            feeBasisPoints,
            pendingEntryFeeUpdate.activationTimestamp
        );

        return true;
    }

    function setExitFee(
        uint256 feeBasisPoints
    ) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE) revert InvalidFee();

        pendingExitFeeUpdate = PendingFeeUpdate({
            value: feeBasisPoints,
            activationTimestamp: block.timestamp + FEE_UPDATE_DELAY
        });

        emit NewPendingExitFeeUpdate(
            feeBasisPoints,
            pendingExitFeeUpdate.activationTimestamp
        );

        return true;
    }

    function setManagementFee(uint256 feeBasisPoints) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE) revert InvalidFee();

        pendingManagementFeeUpdate = PendingFeeUpdate({
            value: feeBasisPoints,
            activationTimestamp: block.timestamp + FEE_UPDATE_DELAY
        });

        emit NewPendingManagementFeeUpdate(
            feeBasisPoints,
            pendingManagementFeeUpdate.activationTimestamp
        );

        return true;
    }

    function enforceNewEntryFee() external onlyOwner returns (bool) {
        if (pendingEntryFeeUpdate.activationTimestamp == 0)
            revert NoPendingFeeUpdate();

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingEntryFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(
                block.timestamp,
                pendingEntryFeeUpdate.activationTimestamp
            );
        }

        entryFeeBasisPoints = pendingEntryFeeUpdate.value;

        delete pendingEntryFeeUpdate;

        emit EntryFeeEnforced(entryFeeBasisPoints);
        return true;
    }

    function enforceNewExitFee() external onlyOwner returns (bool) {
        if (pendingExitFeeUpdate.activationTimestamp == 0)
            revert NoPendingFeeUpdate();

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingExitFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(
                block.timestamp,
                pendingExitFeeUpdate.activationTimestamp
            );
        }

        exitFeeBasisPoints = pendingExitFeeUpdate.value;

        delete pendingExitFeeUpdate;

        emit ExitFeeEnforced(exitFeeBasisPoints);
        return true;
    }

    function enforceNewManagementFee() external onlyOwner returns (bool) {
        if (pendingManagementFeeUpdate.activationTimestamp == 0)
            revert NoPendingFeeUpdate();

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingManagementFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(
                block.timestamp,
                pendingManagementFeeUpdate.activationTimestamp
            );
        }

        managementFeeBasisPoints = pendingManagementFeeUpdate.value;

        delete pendingManagementFeeUpdate;

        emit ManagementFeeEnforced(managementFeeBasisPoints);
        return true;
    }

    function setEntryFeeCollector(address collector) external onlyOwner {
        entryFeeCollector = collector;
    }

    function setExitFeeCollector(address collector) external onlyOwner {
        exitFeeCollector = collector;
    }

    function setManagementFeeCollector(address collector) external onlyOwner {
        managementFeeCollector = collector;
    }

    function collectManagementFees() external onlyOwner returns (uint256) {
        return _collectManagementFees();
    }

    // === Fee operations ===

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _feeOnRaw(
        uint256 assets,
        uint256 feeBasisPoints
    ) private pure returns (uint256) {
        return
            assets.mulDiv(
                feeBasisPoints,
                _BASIS_POINT_SCALE,
                Math.Rounding.Ceil
            );
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _feeOnTotal(
        uint256 assets,
        uint256 feeBasisPoints
    ) private pure returns (uint256) {
        return
            assets.mulDiv(
                feeBasisPoints,
                feeBasisPoints + _BASIS_POINT_SCALE,
                Math.Rounding.Ceil
            );
    }

    // === Fee collection ===

    function _collectManagementFees() internal virtual returns (uint256) {
        if (managementFeeBasisPoints == 0) return 0;

        uint256 timePassed = block.timestamp - lastManagementFeeCollection;
        uint256 totalAssets = super.totalAssets();

        // Calculate annual fee pro-rated by time passed
        uint256 fee = totalAssets.mulDiv(
            managementFeeBasisPoints * timePassed,
            _BASIS_POINT_SCALE * 365 days,
            Math.Rounding.Ceil
        );

        if (fee > 0 && managementFeeCollector != address(this)) {
            SafeERC20.safeTransfer(
                IERC20(asset()),
                managementFeeCollector,
                fee
            );
        }

        lastManagementFeeCollection = block.timestamp;

        emit ManagementFeeCollected(fee);
        return fee;
    }
}
