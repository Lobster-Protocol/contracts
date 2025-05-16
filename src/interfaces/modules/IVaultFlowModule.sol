// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

/**
 * @title IVaultFlowModule Interface
 * @author Lobster
 * @notice Interface for custom deposit and withdrawal logic in vaults
 * @dev This interface allows replacing the vault's default _deposit, _withdraw, max and preview functions
 *      with custom implementation logic. Implementing contracts can provide specialized
 *      asset handling, validation, or accounting during deposit and withdrawal operations.
 *      Each function in this interface can override the corresponding vault function when
 *      the appropriate authorization bit is enabled.
 */
interface IVaultFlowModule {
    /**
     * @notice Custom implementation for vault deposit logic
     * @param caller The address initiating the deposit
     * @param receiver The address that will receive the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to mint
     * @return success Whether the deposit operation succeeded
     * @dev If _DEPOSIT_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's deposit function
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) external returns (bool success);

    /**
     * @notice Custom implementation for vault withdrawal logic
     * @param caller The address initiating the withdrawal
     * @param receiver The address that will receive the assets
     * @param owner The address that owns the shares being burned
     * @param assets The amount of assets being withdrawn
     * @param shares The amount of shares to burn
     * @return success Whether the withdrawal operation succeeded
     * @dev If _WITHDRAW_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's withdrawal function
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) external returns (bool success);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the vault for the receiver
     * @dev This method accounts for deposit limits, vault capacity, and any other constraints.
     *      If MAX_DEPOSIT_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's maxDeposit function
     * @param receiver The address of the receiver of the shares
     * @return maxAssets The maximum amount of assets that can be deposited
     */
    function maxDeposit(
        address receiver
    ) external view returns (uint256 maxAssets);

    /**
     * @notice Returns the maximum amount of shares that can be minted for the receiver
     * @dev This method accounts for mint limits, vault capacity, and any other constraints.
     *      If MAX_MINT_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's maxMint function
     * @param receiver The address of the receiver of the shares
     * @return maxShares The maximum amount of shares that can be minted
     */
    function maxMint(
        address receiver
    ) external view returns (uint256 maxShares);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from owner's balance
     * @dev This method accounts for withdrawal limits, vault liquidity, and owner's balance.
     *      If MAX_WITHDRAW_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's maxWithdraw function
     * @param owner The address of the owner of the assets
     * @return maxAssets The maximum amount of assets that can be withdrawn
     */
    function maxWithdraw(
        address owner
    ) external view returns (uint256 maxAssets);

    /**
     * @notice Returns the maximum amount of shares that can be redeemed from owner's balance
     * @dev This method accounts for redemption limits, vault liquidity, and owner's balance.
     *      If MAX_REDEEM_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's maxRedeem function
     * @param owner The address of the owner of the shares
     * @return maxShares The maximum amount of shares that can be redeemed
     */
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /**
     * @notice Simulates the effects of a deposit at the current block, given current on-chain conditions
     * @dev This method does not account for pending operations that could affect the calculation.
     *      If PREVIEW_DEPOSIT_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's previewDeposit function
     * @param assets The amount of assets to deposit
     * @return shares The amount of shares that would be minted
     */
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /**
     * @notice Simulates the effects of a mint at the current block, given current on-chain conditions
     * @dev This method does not account for pending operations that could affect the calculation.
     *      If PREVIEW_MINT_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's previewMint function
     * @param shares The amount of shares to mint
     * @return assets The amount of assets that would be deposited
     */
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Simulates the effects of a withdrawal at the current block, given current on-chain conditions
     * @dev This method does not account for pending operations that could affect the calculation.
     *      If PREVIEW_WITHDRAW_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's previewWithdraw function
     * @param assets The amount of assets to withdraw
     * @return shares The amount of shares that would be burned
     */
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares);

    /**
     * @notice Simulates the effects of a redemption at the current block, given current on-chain conditions
     * @dev This method does not account for pending operations that could affect the calculation.
     *      If PREVIEW_REDEEM_OVERRIDE_ENABLED authorization bit is set in the LobsterVault, this function overrides the vault's previewRedeem function
     * @param shares The amount of shares to redeem
     * @return assets The amount of assets that would be withdrawn
     */
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);
}

// Authorization bit constants for IVaultFlowModule overrides on vault functions
uint16 constant _DEPOSIT_OVERRIDE_ENABLED = 1 << 0;
uint16 constant _WITHDRAW_OVERRIDE_ENABLED = 1 << 1;
// Max functions
uint16 constant MAX_DEPOSIT_OVERRIDE_ENABLED = 1 << 2;
uint16 constant MAX_MINT_OVERRIDE_ENABLED = 1 << 3;
uint16 constant MAX_WITHDRAW_OVERRIDE_ENABLED = 1 << 4;
uint16 constant MAX_REDEEM_OVERRIDE_ENABLED = 1 << 5;
// Preview functions
uint16 constant PREVIEW_DEPOSIT_OVERRIDE_ENABLED = 1 << 6;
uint16 constant PREVIEW_MINT_OVERRIDE_ENABLED = 1 << 7;
uint16 constant PREVIEW_WITHDRAW_OVERRIDE_ENABLED = 1 << 8;
uint16 constant PREVIEW_REDEEM_OVERRIDE_ENABLED = 1 << 9;