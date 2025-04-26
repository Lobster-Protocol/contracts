// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BASIS_POINT_SCALE, SECONDS_PER_YEAR} from "./Constants.sol";
import {IERC4626FeesEvents, PendingFeeUpdate} from "./ERC4626FeesEvents.sol";

/**
 * @title ERC4626Fees
 * @author Lobster
 * @dev ERC4626 vault with entry/exit and management fees and modular functionalities
 * @notice This contract extends the standard ERC4626 with a comprehensive fee system
 * that includes entry fees (charged when depositing), exit fees (charged when withdrawing),
 * and management fees (charged over time based on assets under management).
 */
abstract contract ERC4626Fees is ERC4626, Ownable, IERC4626FeesEvents {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Constants
    /**
     * @notice Timelock delay for fee updates to take effect
     * @dev This delay gives users time to exit the vault if they disagree with fee changes
     */
    uint256 public constant FEE_UPDATE_DELAY = 2 weeks;

    /**
     * @notice Maximum fee that can be set (30%)
     * @dev Prevents the owner from setting excessively high fees
     */
    uint256 public constant MAX_FEE_BASIS_POINTS = 3000; // 30%

    // Fee configuration
    /**
     * @notice Current entry fee in basis points (1/100 of a percent)
     * @dev Applied when assets are deposited into the vault
     */
    uint16 public entryFeeBasisPoints = 0;

    /**
     * @notice Current exit fee in basis points (1/100 of a percent)
     * @dev Applied when assets are withdrawn from the vault
     */
    uint16 public exitFeeBasisPoints = 0;

    /**
     * @notice Current management fee in basis points (1/100 of a percent) per year
     * @dev Applied continuously based on time and total assets
     */
    uint16 public managementFeeBasisPoints = 0;

    // Fee pending update
    /**
     * @notice Scheduled update to the entry fee
     * @dev Contains the new fee value and when it can be applied
     */
    PendingFeeUpdate public pendingEntryFeeUpdate;

    /**
     * @notice Scheduled update to the exit fee
     * @dev Contains the new fee value and when it can be applied
     */
    PendingFeeUpdate public pendingExitFeeUpdate;

    /**
     * @notice Scheduled update to the management fee
     * @dev Contains the new fee value and when it can be applied
     */
    PendingFeeUpdate public pendingManagementFeeUpdate;

    // Fee recipients
    /**
     * @notice Address that receives all collected fees
     * @dev Fees are minted as new shares to this address
     */
    address public feeCollector;

    // Management fee tracking
    /**
     * @notice Timestamp when management fees were last collected
     * @dev Used to calculate pro-rated management fees
     */
    uint256 public lastFeesCollectedAt;

    /**
     * @dev Constructor
     * @param feeCollector_ The address that will receive fees
     */
    constructor(
        address feeCollector_,
        uint16 entryFeeBasisPoints_,
        uint16 exitFeeBasisPoints_,
        uint16 managementFeeBasisPoints_
    ) {
        require(feeCollector_ != address(0), "FeeVault: Fee collector cannot be zero address");
        feeCollector = feeCollector_;
        entryFeeBasisPoints = entryFeeBasisPoints_;
        exitFeeBasisPoints = exitFeeBasisPoints_;
        managementFeeBasisPoints = managementFeeBasisPoints_;
        lastFeesCollectedAt = block.timestamp;
    }

    /* ================== OVERRIDES ================== */

    /**
     * @dev Override previewDeposit to account for entry fee
     * @param assets The amount of assets to be deposited
     * @return The amount of shares that would be minted after deducting the entry fee
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        // Calculate entry fee
        uint256 fee = _feeOnTotal(assets, entryFeeBasisPoints);
        // Apply fee
        return super.previewDeposit(assets - fee);
    }

    /**
     * @dev Override previewMint to account for entry fee
     * @param shares The amount of shares to be minted
     * @return The amount of assets required, including the entry fee
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        // Determine how many assets are needed to mint `shares`
        uint256 assets = super.previewMint(shares);
        // add entry fee
        return assets + _feeOnRaw(assets, entryFeeBasisPoints);
    }

    /**
     * @dev Preview adding an exit fee on withdraw
     * @param assets The amount of assets to be withdrawn
     * @return The amount of shares that would be burned, including the exit fee
     * @notice Accounts for both exit fee and any pending management fees
     */
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        // simulate the removal of management fees from the vault
        (uint256 assetsLeftInVault,) = _simulateAssetInVaultAfterManagementFeesCollected();

        uint256 exitFee = _feeOnRaw(assets, exitFeeBasisPoints);

        // compute the amount of shares that will be burnt to withdraw `assets`
        // this calculation is based ERC4626._convertToShares(assets,rounding)
        return (assets + exitFee).mulDiv(
            totalSupply() + 10 ** _decimalsOffset(), assetsLeftInVault + 1, Math.Rounding.Ceil
        );
    }

    /**
     * @dev Preview taking an exit fee on redeem
     * @param shares The amount of shares to be redeemed
     * @return The amount of assets that would be received after deducting the exit fee
     * @notice Accounts for both exit fee and any pending management fees
     */
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        // simulate the removal of management fees from the vault
        (uint256 assetsLeftInVault,) = _simulateAssetInVaultAfterManagementFeesCollected();

        // compute the amount of shares that will be burnt to withdraw `assets` without the exit fee
        // this calculation is based ERC4626._convertToAssets(shares,rounding)
        uint256 assets =
            shares.mulDiv(assetsLeftInVault + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);

        // compute the amount of assets that will be withdrawn to redeem `shares`
        return assets - _feeOnTotal(assets, exitFeeBasisPoints);
    }

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the vault
     * @param owner The address of the account that owns shares
     * @return The maximum amount of assets that can be withdrawn
     * @notice Takes into account the exit fee that would be charged
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        uint256 ownerBalance = balanceOf(owner);
        return _convertToAssets(ownerBalance - _feeOnRaw(ownerBalance, exitFeeBasisPoints), Math.Rounding.Floor);
    }

    /**
     * @dev Override deposit to handle fees
     * @param assets The amount of underlying assets to deposit
     * @param receiver The address to receive the minted shares
     * @return The amount of shares minted
     * @notice Collects both entry fees and any pending management fees
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 managementFeeShares = _calculateManagementFee();

        uint256 newShareSupply = totalSupply() + managementFeeShares;
        (uint256 shares, uint256 depositFeeShares) = _previewDepositSimulation(assets, totalAssets(), newShareSupply);

        _deposit(_msgSender(), receiver, assets, shares);

        uint256 totalFeesShares = depositFeeShares + managementFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(totalFeesShares, managementFeeShares, depositFeeShares, 0, block.timestamp);
        }

        return shares;
    }

    /**
     * @notice Override mint to handle fees
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the minted shares
     * @return The amount of assets deposited
     * @notice Collects both entry fees and any pending management fees
     */
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 managementFeeShares = _calculateManagementFee();

        uint256 newShareSupply = totalSupply() + managementFeeShares;

        (uint256 assets, uint256 depositFeeShares) = _previewMintSimulation(shares, totalAssets(), newShareSupply);

        _deposit(_msgSender(), receiver, assets, shares);

        uint256 totalFeesShares = depositFeeShares + managementFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(totalFeesShares, managementFeeShares, depositFeeShares, 0, block.timestamp);
        }

        return assets;
    }

    /**
     * @dev Override withdraw to handle fees
     * @param assets The amount of underlying assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address that owns the shares
     * @return The amount of shares burned
     * @notice Collects both exit fees and any pending management fees
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 managementFeeShares = _calculateManagementFee();

        uint256 newShareSupply = totalSupply() + managementFeeShares;

        (uint256 shares, uint256 exitFeeAssets) = _previewWithdrawSimulation(assets, totalAssets(), newShareSupply);

        uint256 exitFeeShares = _convertToShares(exitFeeAssets, Math.Rounding.Floor);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        uint256 totalFeesShares = exitFeeShares + managementFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(totalFeesShares, managementFeeShares, 0, exitFeeShares, block.timestamp);
        }

        return shares;
    }

    /**
     * @dev Override redeem to handle fees
     * @param shares The amount of shares to redeem
     * @param receiver The address to receive the assets
     * @param owner The address that owns the shares
     * @return The amount of assets received
     * @notice Collects both exit fees and any pending management fees
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 managementFeeShares = _calculateManagementFee();

        uint256 newShareSupply = totalSupply() + managementFeeShares;

        (uint256 assets, uint256 exitFeeAssets) = _previewRedeemSimulation(shares, totalAssets(), newShareSupply);

        uint256 exitFeeShares = _convertToShares(exitFeeAssets, Math.Rounding.Floor);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        uint256 totalFeesShares = exitFeeShares + managementFeeShares;

        if (totalFeesShares > 0 && feeCollector != address(this)) {
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(totalFeesShares, managementFeeShares, 0, exitFeeShares, block.timestamp);
        }
        return assets;
    }

    /* ================== FEE COLLECTION ================== */

    /**
     * @dev Collect management fees
     * @return totalFees The total fees collected in shares
     * @notice Can only be called by the owner
     * @notice This allows manual collection of management fees
     */
    function collectFees() public onlyOwner returns (uint256 totalFees) {
        return _collectAllFees(0, 0);
    }

    /**
     * @dev Internal function to collect all fees
     * @param entryFeeShares Entry fee shares to add to the collection
     * @param exitFeeShares Exit fee shares to add to the collection
     * @return totalFeesShares The total fees collected in shares
     * @notice Updates lastFeesCollectedAt to the current timestamp
     */
    function _collectAllFees(
        uint256 entryFeeShares,
        uint256 exitFeeShares
    )
        internal
        returns (uint256 totalFeesShares)
    {
        uint256 managementFeeShares = _calculateManagementFee();

        totalFeesShares = managementFeeShares + entryFeeShares + exitFeeShares;

        if (totalFeesShares > 0 && totalAssets() > totalFeesShares) {
            // Transfer fees to fee collector
            _mint(feeCollector, totalFeesShares);

            emit FeeCollected(totalFeesShares, managementFeeShares, entryFeeShares, exitFeeShares, block.timestamp);
        }

        // save management fee timestamp
        lastFeesCollectedAt = block.timestamp;

        return totalFeesShares;
    }

    /* ================== SHARE VALUE ================== */

    /**
     * @dev Calculate current share value
     * @return The value of one share in terms of the underlying asset
     * @notice Returns 0 if there is no supply
     */
    function _calculateShareValue() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return totalAssets().mulDiv(10 ** decimals(), supply, Math.Rounding.Floor);
    }

    /**
     * @dev Calculates the fees that should be added to an amount `assets` that does not already include fees
     * @param amount The base amount to calculate fees on
     * @param feeBasisPoints The fee rate in basis points
     * @return The fee amount to be added
     * @notice Used in {IERC4626-mint} and {IERC4626-withdraw} operations
     */
    function _feeOnRaw(uint256 amount, uint256 feeBasisPoints) private pure returns (uint256) {
        return amount.mulDiv(feeBasisPoints, BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    /**
     * @dev Calculates the fee part of an amount `assets` that already includes fees
     * @param amount The total amount including fees
     * @param feeBasisPoints The fee rate in basis points
     * @return The fee portion of the total amount
     * @notice Used in {IERC4626-deposit} and {IERC4626-redeem} operations
     */
    function _feeOnTotal(uint256 amount, uint256 feeBasisPoints) private pure returns (uint256) {
        return amount.mulDiv(feeBasisPoints, feeBasisPoints + BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    /**
     * @dev Calculate management fee
     * @return The management fee amount in shares
     * @notice Calculates the pro-rated management fee based on time elapsed since last collection
     */
    function _calculateManagementFee() internal view returns (uint256) {
        if (managementFeeBasisPoints == 0 || lastFeesCollectedAt == block.timestamp) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - lastFeesCollectedAt;

        // Calculate pro-rated management fee: (assets * fee_bp * timeElapsed) / (YEAR * BPS)
        return (totalSupply() * managementFeeBasisPoints).mulDiv(
            timeElapsed, BASIS_POINT_SCALE * SECONDS_PER_YEAR, Math.Rounding.Ceil
        );
    }

    /* ================== FEE CONFIGURATION ================== */

    /**
     * @notice Schedules an update to the entry fee
     * @param feeBasisPoints New entry fee in basis points
     * @return success True if the update was scheduled successfully
     * @dev The new fee will be pending for FEE_UPDATE_DELAY before it can be enforced
     * @dev Only callable by the owner
     */
    function setEntryFee(uint16 feeBasisPoints) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

        pendingEntryFeeUpdate =
            PendingFeeUpdate({value: feeBasisPoints, activationTimestamp: block.timestamp + FEE_UPDATE_DELAY});

        emit NewPendingEntryFeeUpdate(feeBasisPoints, pendingEntryFeeUpdate.activationTimestamp);

        return true;
    }

    /**
     * @notice Schedules an update to the exit fee
     * @param feeBasisPoints New exit fee in basis points
     * @return success True if the update was scheduled successfully
     * @dev The new fee will be pending for FEE_UPDATE_DELAY before it can be enforced
     * @dev Only callable by the owner
     */
    function setExitFee(uint16 feeBasisPoints) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

        pendingExitFeeUpdate =
            PendingFeeUpdate({value: feeBasisPoints, activationTimestamp: block.timestamp + FEE_UPDATE_DELAY});

        emit NewPendingExitFeeUpdate(feeBasisPoints, pendingExitFeeUpdate.activationTimestamp);

        return true;
    }

    /**
     * @notice Schedules an update to the management fee
     * @param feeBasisPoints New management fee in basis points
     * @return success True if the update was scheduled successfully
     * @dev The new fee will be pending for FEE_UPDATE_DELAY before it can be enforced
     * @dev Only callable by the owner
     */
    function setManagementFee(uint16 feeBasisPoints) external onlyOwner returns (bool) {
        if (feeBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFee();

        pendingManagementFeeUpdate =
            PendingFeeUpdate({value: feeBasisPoints, activationTimestamp: block.timestamp + FEE_UPDATE_DELAY});

        emit NewPendingManagementFeeUpdate(feeBasisPoints, pendingManagementFeeUpdate.activationTimestamp);

        return true;
    }

    /**
     * @notice Enforces the pending entry fee update
     * @return success True if the new fee was successfully enforced
     * @dev Only callable by the owner after the activation timestamp has passed
     * @dev Reverts if there is no pending update or if the activation time hasn't arrived
     */
    function enforceNewEntryFee() external onlyOwner returns (bool) {
        if (pendingEntryFeeUpdate.activationTimestamp == 0) {
            revert NoPendingFeeUpdate();
        }

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingEntryFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(block.timestamp, pendingEntryFeeUpdate.activationTimestamp);
        }

        entryFeeBasisPoints = pendingEntryFeeUpdate.value;

        delete pendingEntryFeeUpdate;

        emit EntryFeeEnforced(entryFeeBasisPoints);
        return true;
    }

    /**
     * @notice Enforces the pending exit fee update
     * @return success True if the new fee was successfully enforced
     * @dev Only callable by the owner after the activation timestamp has passed
     * @dev Reverts if there is no pending update or if the activation time hasn't arrived
     */
    function enforceNewExitFee() external onlyOwner returns (bool) {
        if (pendingExitFeeUpdate.activationTimestamp == 0) {
            revert NoPendingFeeUpdate();
        }

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingExitFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(block.timestamp, pendingExitFeeUpdate.activationTimestamp);
        }

        exitFeeBasisPoints = pendingExitFeeUpdate.value;

        delete pendingExitFeeUpdate;

        emit ExitFeeEnforced(exitFeeBasisPoints);
        return true;
    }

    /**
     * @notice Enforces the pending management fee update
     * @return success True if the new fee was successfully enforced
     * @dev Only callable by the owner after the activation timestamp has passed
     * @dev Reverts if there is no pending update or if the activation time hasn't arrived
     * @dev Collects any outstanding management fees before updating the rate
     */
    function enforceNewManagementFee() external onlyOwner returns (bool) {
        if (pendingManagementFeeUpdate.activationTimestamp == 0) {
            revert NoPendingFeeUpdate();
        }

        // should revert if the activation timestamp is in the future
        if (block.timestamp < pendingManagementFeeUpdate.activationTimestamp) {
            revert ActivationTimestampNotReached(block.timestamp, pendingManagementFeeUpdate.activationTimestamp);
        }

        // collect fees
        _collectAllFees(0, 0);

        managementFeeBasisPoints = pendingManagementFeeUpdate.value;

        delete pendingManagementFeeUpdate;

        emit ManagementFeeEnforced(managementFeeBasisPoints);

        return true;
    }

    /**
     * @notice Update fee collector address
     * @param newFeeCollector The new address to receive fees
     * @dev Cannot be the zero address
     * @dev Only callable by the owner
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        require(newFeeCollector != address(0), "FeeVault: Fee collector cannot be zero address");
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(feeCollector);
    }

    /* ================== SIMULATION ================== */

    /**
     * @notice Simulates the vault's assets after management fees are collected
     * @return assetsLeft Assets remaining in the vault after fees
     * @return managementFeeShares Management fee amount in shares
     * @dev Used for accurate asset calculations in preview functions
     */
    function _simulateAssetInVaultAfterManagementFeesCollected()
        internal
        view
        returns (uint256 assetsLeft, uint256 managementFeeShares)
    {
        uint256 totalAssets = totalAssets();

        managementFeeShares = _calculateManagementFee();

        uint256 totalFees = managementFeeShares;

        if (totalFees > totalAssets) {
            // Not enough assets to cover fees
            // Should not happen in practice
            revert("FeeVault: Insufficient assets to cover fees");
        }

        assetsLeft = totalAssets - _convertToShares(totalFees, Math.Rounding.Ceil);

        return (assetsLeft, managementFeeShares);
    }

    /**
     * @notice Simulates a deposit operation with current vault state
     * @param assetsToDeposit The amount of assets to deposit
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @return shares The number of shares that would be minted
     * @return fee The fee amount in shares
     * @dev Used internally by deposit and other functions to calculate expected results
     */
    function _previewDepositSimulation(
        uint256 assetsToDeposit,
        uint256 vaultAssets,
        uint256 vaultSupply
    )
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        // Calculate entry fee
        fee = _feeOnTotal(assetsToDeposit, entryFeeBasisPoints);

        // Apply fee
        return (
            _convertToSharesSimulation(assetsToDeposit - fee, vaultAssets, vaultSupply, Math.Rounding.Floor),
            _convertToShares(fee, Math.Rounding.Ceil)
        );
    }

    /**
     * @notice Simulates a mint operation with current vault state
     * @param sharesToMint The amount of shares to mint
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @return assets The amount of assets that would be required
     * @return fee The fee amount in shares
     * @dev Used internally by mint and other functions to calculate expected results
     */
    function _previewMintSimulation(
        uint256 sharesToMint,
        uint256 vaultAssets,
        uint256 vaultSupply
    )
        internal
        view
        returns (uint256 assets, uint256 fee)
    {
        // Calculate entry fee
        fee = _feeOnRaw(sharesToMint, entryFeeBasisPoints);

        // Apply fee
        return (_convertToAssetsSimulation(sharesToMint + fee, vaultAssets, vaultSupply, Math.Rounding.Ceil), fee);
    }

    /**
     * @notice Simulates a withdraw operation with current vault state
     * @param assetsToWithdraw The amount of assets to withdraw
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @return shares The number of shares that would be burned
     * @return fee The fee amount in assets
     * @dev Used internally by withdraw and other functions to calculate expected results
     */
    function _previewWithdrawSimulation(
        uint256 assetsToWithdraw,
        uint256 vaultAssets,
        uint256 vaultSupply
    )
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        fee = _feeOnRaw(assetsToWithdraw, exitFeeBasisPoints);
        return (_convertToSharesSimulation(assetsToWithdraw + fee, vaultAssets, vaultSupply, Math.Rounding.Floor), fee);
    }

    /**
     * @notice Simulates a redeem operation with current vault state
     * @param sharesToRedeem The amount of shares to redeem
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @return assets The amount of assets that would be received
     * @return fee The fee amount in assets
     * @dev Used internally by redeem and other functions to calculate expected results
     */
    function _previewRedeemSimulation(
        uint256 sharesToRedeem,
        uint256 vaultAssets,
        uint256 vaultSupply
    )
        internal
        view
        returns (uint256 assets, uint256 fee)
    {
        uint256 assets_ = _convertToAssetsSimulation(sharesToRedeem, vaultAssets, vaultSupply, Math.Rounding.Floor);
        fee = _feeOnTotal(assets_, exitFeeBasisPoints);
        return (assets_ - fee, fee);
    }

    /**
     * @notice Converts assets to shares based on provided vault state
     * @param assets The amount of assets to convert
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @param rounding The rounding direction for the calculation
     * @return The number of shares equivalent to the assets
     * @dev Uses a custom calculation that simulates the vault state
     */
    function _convertToSharesSimulation(
        uint256 assets,
        uint256 vaultAssets,
        uint256 vaultSupply,
        Math.Rounding rounding
    )
        internal
        view
        virtual
        returns (uint256)
    {
        return assets.mulDiv(vaultSupply + 10 ** _decimalsOffset(), vaultAssets + 1, rounding);
    }

    /**
     * @notice Converts shares to assets based on provided vault state
     * @param shares The amount of shares to convert
     * @param vaultAssets The current total assets in the vault
     * @param vaultSupply The current total supply of shares
     * @param rounding The rounding direction for the calculation
     * @return The amount of assets equivalent to the shares
     * @dev Uses a custom calculation that simulates the vault state
     */
    function _convertToAssetsSimulation(
        uint256 shares,
        uint256 vaultAssets,
        uint256 vaultSupply,
        Math.Rounding rounding
    )
        internal
        view
        virtual
        returns (uint256)
    {
        return shares.mulDiv(vaultAssets + 1, vaultSupply + 10 ** _decimalsOffset(), rounding);
    }
}
