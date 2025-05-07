// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

/**
 * @title IVaultFlowModule Interface
 * @author Lobster
 * @notice Interface for custom deposit and withdrawal logic in vaults
 * @dev This interface allows replacing the vault's default _deposit and _withdraw functions
 *      with custom implementation logic. Implementing contracts can provide specialized
 *      asset handling, validation, or accounting during deposit and withdrawal operations.
 */
interface IVaultFlowModule {
    /**
     * @notice Custom implementation for vault deposit logic
     * @param caller The address initiating the deposit
     * @param receiver The address that will receive the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to mint
     * @return success Whether the deposit operation succeeded
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
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) external returns (bool success);

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, through a withdraw call.
     *
     * - MUST return a limited value if owner is subject to some withdrawal limit or timelock.
     * - MUST NOT revert.
     */
    function maxWithdraw(
        address owner
    ) external view returns (uint256 maxAssets);
}
