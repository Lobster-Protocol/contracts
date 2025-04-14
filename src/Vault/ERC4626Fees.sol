// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BASIS_POINT_SCALE, SECONDS_PER_YEAR} from "./Constants.sol";
import {IERC4626FeesEvents, PendingFeeUpdate} from "./ERC4626FeesEvents.sol";
import "forge-std/Test.sol";

/**
 * @title ERC4626Fees
 * @dev ERC4626 vault with entry/exit, management, and performance fees
 */
abstract contract ERC4626Fees is ERC4626, Ownable, IERC4626FeesEvents {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant FEE_UPDATE_DELAY = 2 weeks;
    uint256 public constant MAX_FEE_BASIS_POINTS = 3000; // 30%

    // Fee configuration
    uint256 public entryFeeBasisPoints = 0;
    uint256 public exitFeeBasisPoints = 0;
    uint256 public managementFeeBasisPoints = 0;
    uint256 public performanceFeeBasisPoints = 0;

    // Fee pending update
    PendingFeeUpdate public pendingEntryFeeUpdate;
    PendingFeeUpdate public pendingExitFeeUpdate;
    PendingFeeUpdate public pendingManagementFeeUpdate;
    PendingFeeUpdate public pendingPerformanceFeeUpdate;

    // Fee recipients
    address public feeCollector;

    // Performance fee tracking
    uint256 public highWaterMark;

    // Management fee tracking
    uint256 public lastFeesCollectedAt;

    /**
     * @dev Constructor
     * @param feeCollector_ The address that will receive fees
     */
    constructor(address feeCollector_) {
        require(
            feeCollector_ != address(0),
            "FeeVault: Fee collector cannot be zero address"
        );
        feeCollector = feeCollector_;
        lastFeesCollectedAt = block.timestamp;
    }

    /* ================== OVERRIDES ================== */

    /**
     * @dev Override previewDeposit to account for entry fee
     */
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        // Calculate entry fee
        uint256 fee = _feeOnTotal(assets, entryFeeBasisPoints);
        // Apply fee
        return super.previewDeposit(assets - fee);
    }

    /**
     * @dev Override previewMint to account for entry fee
     */
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        // Determine how many assets are needed to mint `shares`
        uint256 assets = super.previewMint(shares);
        // add entry fee
        return assets + _feeOnRaw(assets, entryFeeBasisPoints);
    }

    /// @dev Preview adding an exit fee on withdraw. See {IERC4626-previewWithdraw}.
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        // simulate the removal of management and performance fees from the vault
        (
            uint256 assetsLeftInVault,
            ,

        ) = _simulateAssetInVaultAfterManagementAndPerformanceFeesCollected();

        uint256 exitFee = _feeOnRaw(assets, exitFeeBasisPoints);

        // compute the amount of shares that will be burnt to withdraw `assets`
        // this calculation is based ERC4626._convertToShares(assets,rounding)
        return
            (assets + exitFee).mulDiv(
                totalSupply() + 10 ** _decimalsOffset(),
                assetsLeftInVault + 1,
                Math.Rounding.Ceil
            );
    }

    /// @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        // simulate the removal of management and performance fees from the vault
        (
            uint256 assetsLeftInVault,
            ,

        ) = _simulateAssetInVaultAfterManagementAndPerformanceFeesCollected();

        // compute the amount of shares that will be burnt to withdraw `assets` without the exit fee
        // this calculation is based ERC4626._convertToAssets(shares,rounding)
        uint256 assets = shares.mulDiv(
            assetsLeftInVault + 1,
            totalSupply() + 10 ** _decimalsOffset(),
            Math.Rounding.Floor
        );

        // compute the amount of assets that will be withdrawn to redeem `shares`
        return assets - _feeOnTotal(assets, exitFeeBasisPoints);
    }

    /** @dev See {IERC4626-maxWithdraw}. */
    function maxWithdraw(
        address owner
    ) public view virtual override returns (uint256) {
        uint256 ownerBalance = balanceOf(owner);
        return
            _convertToAssets(
                ownerBalance - _feeOnRaw(ownerBalance, exitFeeBasisPoints),
                Math.Rounding.Floor
            );
    }

    /**
     * @dev Override deposit to handle fees
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 managementFeeShares = _calculateManagementFee();
        uint256 performanceFeeShares = _calculatePerformanceFee();

        uint256 newShareSupply = totalSupply() +
            managementFeeShares +
            performanceFeeShares;
        (uint256 shares, uint256 depositFeeShares) = _previewDepositSimulation(
            assets,
            totalAssets(),
            newShareSupply
        );

        _deposit(_msgSender(), receiver, assets, shares);

        uint256 totalFeesShares = depositFeeShares +
            managementFeeShares +
            performanceFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(
                totalFeesShares,
                managementFeeShares,
                performanceFeeShares,
                depositFeeShares,
                0,
                block.timestamp
            );
        }

        return shares;
    }

    /**
     * @notice override mint to handle fees
     */
    function mint(
        uint256 shares,
        address receiver
    ) public virtual override returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 managementFeeShares = _calculateManagementFee();
        uint256 performanceFeeShares = _calculatePerformanceFee();

        uint256 newShareSupply = totalSupply() +
            managementFeeShares +
            performanceFeeShares;

        (uint256 assets, uint256 depositFeeShares) = _previewMintSimulation(
            shares,
            totalAssets(),
            newShareSupply
        );

        _deposit(_msgSender(), receiver, assets, shares);

        uint256 totalFeesShares = depositFeeShares +
            managementFeeShares +
            performanceFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(
                totalFeesShares,
                managementFeeShares,
                performanceFeeShares,
                depositFeeShares,
                0,
                block.timestamp
            );
        }

        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 managementFeeShares = _calculateManagementFee();
        uint256 performanceFeeShares = _calculatePerformanceFee();

        uint256 newShareSupply = totalSupply() +
            managementFeeShares +
            performanceFeeShares;

        (uint256 shares, uint256 exitFeeAssets) = _previewWithdrawSimulation(
            assets,
            totalAssets(),
            newShareSupply
        );
        console.log("shares: ", shares);

        uint256 exitFeeShares = _convertToShares(
            exitFeeAssets,
            Math.Rounding.Floor
        );

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        uint256 totalFeesShares = exitFeeShares +
            managementFeeShares +
            performanceFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(
                totalFeesShares,
                managementFeeShares,
                performanceFeeShares,
                0,
                exitFeeShares,
                block.timestamp
            );
        }

        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 managementFeeShares = _calculateManagementFee();
        uint256 performanceFeeShares = _calculatePerformanceFee();

        uint256 newShareSupply = totalSupply() +
            managementFeeShares +
            performanceFeeShares;

        (uint256 assets, uint256 exitFeeAssets) = _previewRedeemSimulation(
            shares,
            totalAssets(),
            newShareSupply
        );

        uint256 exitFeeShares = _convertToShares(
            exitFeeAssets,
            Math.Rounding.Floor
        );

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        uint256 totalFeesShares = exitFeeShares +
            managementFeeShares +
            performanceFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(
                totalFeesShares,
                managementFeeShares,
                performanceFeeShares,
                0,
                exitFeeShares,
                block.timestamp
            );
        }
        return assets;
    }

    /* ================== FEE COLLECTION ================== */

    /**
     * @dev Collect management and performance fees
     * @return totalFees The total fees collected
     */
    function collectFees() public onlyOwner returns (uint256 totalFees) {
        return _collectAllFees(0, 0);
    }

    function _collectAllFees(
        uint256 entryFeeShares,
        uint256 exitFeeShares
    ) internal returns (uint256 totalFeesShares) {
        uint256 managementFeeShares = _calculateManagementFee();

        uint256 performanceFeeShares = _calculatePerformanceFee();

        totalFeesShares =
            managementFeeShares +
            performanceFeeShares +
            entryFeeShares +
            exitFeeShares;

        if (totalFeesShares > 0 && totalAssets() > totalFeesShares) {
            // Transfer fees to fee collector
            _mint(feeCollector, totalFeesShares);

            // Update state
            lastFeesCollectedAt = block.timestamp;

            if (performanceFeeShares > 0) {
                // Update high water mark to current share price after fee collection
                highWaterMark = _calculateShareValue();
            }

            emit FeeCollected(
                totalFeesShares,
                managementFeeShares,
                performanceFeeShares,
                entryFeeShares,
                exitFeeShares,
                block.timestamp
            );
        }

        // save management fee timestamp
        lastFeesCollectedAt = block.timestamp;

        return totalFeesShares;
    }

    /* ==================  ================== */

    /**
     * @dev Calculate current share value
     * @return The value of one share in terms of the underlying asset
     */
    function _calculateShareValue() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return
            totalAssets().mulDiv(10 ** decimals(), supply, Math.Rounding.Floor);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _feeOnRaw(
        uint256 amount,
        uint256 feeBasisPoints
    ) private pure returns (uint256) {
        return
            amount.mulDiv(
                feeBasisPoints,
                BASIS_POINT_SCALE,
                Math.Rounding.Ceil
            );
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _feeOnTotal(
        uint256 amount,
        uint256 feeBasisPoints
    ) private pure returns (uint256) {
        return
            amount.mulDiv(
                feeBasisPoints,
                feeBasisPoints + BASIS_POINT_SCALE,
                Math.Rounding.Ceil
            );
    }

    /**
     * @dev Calculate management fee
     * @return The management fee amount in shares
     */
    function _calculateManagementFee() internal view returns (uint256) {
        if (
            managementFeeBasisPoints == 0 ||
            lastFeesCollectedAt == block.timestamp
        ) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - lastFeesCollectedAt;

        // Calculate pro-rated management fee: (assets * fee_bp * timeElapsed) / (YEAR * BPS)
        return
            (totalSupply() * managementFeeBasisPoints).mulDiv(
                timeElapsed,
                BASIS_POINT_SCALE * SECONDS_PER_YEAR,
                Math.Rounding.Ceil
            );
    }

    /**
     * @dev Calculate performance fee
     * @return The performance fee amount in shares
     */
    function _calculatePerformanceFee() internal view returns (uint256) {
        // todo: might be simplified
        if (performanceFeeBasisPoints == 0 || totalSupply() == 0) {
            return 0;
        }

        uint256 currentShareValue = _calculateShareValue();

        // Only charge performance fee if current value exceeds high water mark
        if (currentShareValue <= highWaterMark) {
            return 0;
        }

        uint256 profit = currentShareValue - highWaterMark;
        uint256 totalProfit = profit.mulDiv(
            totalSupply(),
            10 ** decimals(),
            Math.Rounding.Floor
        );

        return
            _convertToShares(
                totalProfit.mulDiv(
                    performanceFeeBasisPoints,
                    BASIS_POINT_SCALE,
                    Math.Rounding.Floor
                ),
                Math.Rounding.Ceil
            );
    }

    /* ================== FEE CONFIGURATION ================== */

    function setEntryFee(
        uint256 feeBasisPoints
    ) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

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
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

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

    function setManagementFee(
        uint256 feeBasisPoints
    ) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

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

    function setPerformanceFee(
        uint256 feeBasisPoints
    ) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

        pendingPerformanceFeeUpdate = PendingFeeUpdate({
            value: feeBasisPoints,
            activationTimestamp: block.timestamp + FEE_UPDATE_DELAY
        });

        emit NewPendingPerformanceFeeUpdate(
            feeBasisPoints,
            pendingPerformanceFeeUpdate.activationTimestamp
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

        // collect fees
        _collectAllFees(0, 0);
        console.log("block timestamp: ", block.timestamp);
        managementFeeBasisPoints = pendingManagementFeeUpdate.value;

        delete pendingManagementFeeUpdate;

        emit ManagementFeeEnforced(managementFeeBasisPoints);

        return true;
    }

    function enforceNewPerformanceFee() external onlyOwner returns (bool) {
        if (pendingPerformanceFeeUpdate.activationTimestamp == 0)
            revert NoPendingFeeUpdate();

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingPerformanceFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(
                block.timestamp,
                pendingPerformanceFeeUpdate.activationTimestamp
            );
        }

        // collect fees
        _collectAllFees(0, 0);

        performanceFeeBasisPoints = pendingPerformanceFeeUpdate.value;

        delete pendingPerformanceFeeUpdate;

        emit PerformanceFeeEnforced(performanceFeeBasisPoints);

        return true;
    }

    /**
     * @dev Update fee collector address
     * @notice Only owner can call this function
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        require(
            newFeeCollector != address(0),
            "FeeVault: Fee collector cannot be zero address"
        );
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(feeCollector);
    }

    /* ================== SIMULATION ================== */

    function _simulateAssetInVaultAfterManagementAndPerformanceFeesCollected()
        internal
        view
        returns (
            uint256 assetsLeft,
            uint256 managementFeeShares,
            uint256 performanceFeeShares
        )
    {
        uint256 totalAssets = totalAssets();

        managementFeeShares = _calculateManagementFee();
        performanceFeeShares = _calculatePerformanceFee();

        uint256 totalFees = managementFeeShares + performanceFeeShares;

        if (totalFees > totalAssets) {
            // Not enough assets to cover fees
            // Should not happen in practice
            revert("FeeVault: Insufficient assets to cover fees");
        }

        assetsLeft =
            totalAssets -
            _convertToShares(totalFees, Math.Rounding.Ceil);

        return (assetsLeft, managementFeeShares, performanceFeeShares);
    }

    /**
     * @dev preview a deposit depending on the vaults assets & supply
     */
    function _previewDepositSimulation(
        uint256 assetsToDeposit,
        uint256 vaultAssets,
        uint256 vaultSupply
    ) internal view returns (uint256 shares, uint256 fee) {
        // Calculate entry fee
        fee = _feeOnTotal(assetsToDeposit, entryFeeBasisPoints);

        // Apply fee
        return (
            _convertToSharesSimulation(
                assetsToDeposit - fee,
                vaultAssets,
                vaultSupply,
                Math.Rounding.Floor
            ),
            _convertToShares(fee, Math.Rounding.Ceil)
        );
    }

    /**
     * @dev preview a mint depending on the vaults assets & supply
     */
    function _previewMintSimulation(
        uint256 sharesToMint,
        uint256 vaultAssets,
        uint256 vaultSupply
    ) internal view returns (uint256 assets, uint256 fee) {
        // Calculate entry fee
        fee = _feeOnRaw(sharesToMint, entryFeeBasisPoints);

        // Apply fee
        return (
            _convertToAssetsSimulation(
                sharesToMint + fee,
                vaultAssets,
                vaultSupply,
                Math.Rounding.Ceil
            ),
            fee
        );
    }

    /**
     * @dev preview a withdraw depending on the vaults assets & supply
     */
    function _previewWithdrawSimulation(
        uint256 assetsToWithdraw,
        uint256 vaultAssets,
        uint256 vaultSupply
    ) internal view returns (uint256, uint256 fee) {
        fee = _feeOnRaw(assetsToWithdraw, exitFeeBasisPoints);
        return (
            _convertToSharesSimulation(
                assetsToWithdraw + fee,
                vaultAssets,
                vaultSupply,
                Math.Rounding.Floor
            ),
            fee
        );
    }

    /**
     * @dev preview a redeem depending on the vaults assets & supply
     */
    function _previewRedeemSimulation(
        uint256 sharesToRedeem,
        uint256 vaultAssets,
        uint256 vaultSupply
    ) internal view returns (uint256, uint256 fee) {
        uint256 assets = _convertToAssetsSimulation(
            sharesToRedeem,
            vaultAssets,
            vaultSupply,
            Math.Rounding.Floor
        );
        fee = _feeOnTotal(assets, exitFeeBasisPoints);
        return (assets - fee, fee);
    }

    /**
     * @dev _convertToShares depending on the vaults assets & supply
     */
    function _convertToSharesSimulation(
        uint256 assets,
        uint256 vaultAssets,
        uint256 vaultSupply,
        Math.Rounding rounding
    ) internal view virtual returns (uint256) {
        return
            assets.mulDiv(
                vaultSupply + 10 ** _decimalsOffset(),
                vaultAssets + 1,
                rounding
            );
    }

    /**
     * @dev _convertToAssets depending on the vaults assets & supply
     */
    function _convertToAssetsSimulation(
        uint256 shares,
        uint256 vaultAssets,
        uint256 vaultSupply,
        Math.Rounding rounding
    ) internal view virtual returns (uint256) {
        return
            shares.mulDiv(
                vaultAssets + 1,
                vaultSupply + 10 ** _decimalsOffset(),
                rounding
            );
    }
}
