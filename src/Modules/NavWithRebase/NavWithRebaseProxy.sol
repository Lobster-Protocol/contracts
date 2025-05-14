// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LobsterVault} from "../../Vault/Vault.sol";
import {NavWithRebase} from "./NavWithRebase.sol";

/**
 * @title NavWithRebaseProxy
 * @author Lobster
 * @notice This contract is a proxy for the NavWithRebase module.
 * It is used to rebase and interact with the Vault (deposits, withdrawals, etc.)
 * in only one transaction.
 * @dev This contract provides convenience functions to execute vault operations
 * and rebase actions atomically.
 */
contract NavWithRebaseProxy {
    /**
     * @notice Reference to the LobsterVault contract
     * @dev This is immutable and set in the constructor
     */
    LobsterVault public immutable vault;

    /**
     * @notice Reference to the NavWithRebase module for NAV calculations and rebasing
     * @dev This is immutable and set in the constructor based on the vault's navModule
     */
    NavWithRebase public immutable rebasingNavModule;

    /**
     * @notice Reference to the underlying asset token contract
     * @dev This is immutable and set in the constructor based on the vault's asset
     */
    IERC20 public immutable asset;

    /**
     * @notice Initializes the proxy with references to the vault and its components
     * @param _vault Address of the LobsterVault contract
     * @dev Automatically retrieves and stores references to the rebasingNavModule and asset
     */
    constructor(LobsterVault _vault) {
        vault = _vault;
        rebasingNavModule = NavWithRebase(address(vault.navModule()));
        asset = IERC20(vault.asset());
    }

    /**
     * @notice Deposits assets into the vault with optional rebasing before deposit
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the minted shares
     * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
     * @return shares Amount of shares minted to receiver
     * @dev Transfers assets from msg.sender to this contract, then approves and deposits to vault
     */
    function deposit(uint256 assets, address receiver, bytes calldata rebaseData) public returns (uint256 shares) {
        // transfer the assets to the proxy
        asset.transferFrom(msg.sender, address(this), assets);

        // approve the vault to spend the assets
        asset.approve(address(vault), assets);

        if (rebaseData.length > 0) {
            rebase(rebaseData);
        }

        shares = vault.deposit(assets, receiver);
    }

    /**
     * @notice Withdraws assets from the vault with optional rebasing before withdrawal
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the withdrawn assets
     * @param owner Address that owns the shares being burned
     * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
     * @return shares Amount of shares burned from owner
     * @dev Will rebase first if rebaseData is provided, then perform the withdrawal
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bytes calldata rebaseData
    )
        public
        returns (uint256 shares)
    {
        if (rebaseData.length > 0) {
            rebase(rebaseData);
        }

        shares = vault.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Mints a specific amount of shares with optional rebasing before minting
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the minted shares
     * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
     * @return assets Amount of assets pulled from msg.sender
     * @dev Calculates required assets, transfers them to this contract, then mints shares
     */
    function mint(uint256 shares, address receiver, bytes calldata rebaseData) public returns (uint256 assets) {
        // get the expected assets to mint the shares
        uint256 expectedAssets = vault.previewMint(shares);

        // transfer the assets to the proxy
        asset.transferFrom(msg.sender, address(this), expectedAssets);

        // approve the vault to spend the assets
        asset.approve(address(vault), expectedAssets);

        if (rebaseData.length > 0) {
            rebase(rebaseData);
        }

        assets = vault.mint(shares, receiver);
    }

    /**
     * @notice Redeems shares for assets with optional rebasing before redemption
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the redeemed assets
     * @param owner Address that owns the shares being burned
     * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
     * @return assets Amount of assets transferred to receiver
     * @dev Will rebase first if rebaseData is provided, then perform the redemption
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes calldata rebaseData
    )
        public
        returns (uint256 assets)
    {
        if (rebaseData.length > 0) {
            rebase(rebaseData);
        }

        assets = vault.redeem(shares, receiver, owner);
    }

    /**
     * @notice Performs a rebase followed by an arbitrary function call
     * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
     * @param doData Encoded call data containing target address (first 20 bytes) and call data
     * @return true if both operations succeed
     * @dev First 20 bytes of doData must be the target address, remainder is the call data
     * @dev Reverts if the arbitrary call fails
     */
    function rebaseAndDo(bytes calldata rebaseData, bytes calldata doData) public returns (bool) {
        if (rebaseData.length > 0) {
            rebase(rebaseData);
        }

        // decode the data
        address target = address(bytes20(doData[:20]));
        bytes memory data = doData[20:];

        // call the target contract with the data
        (bool success,) = target.call(data);
        require(success, "Call failed");

        return true;
    }

    /**
     * @notice Executes a rebase operation on the NavWithRebase module
     * @param rebaseData Encoded parameters containing newTotalAssets, rebaseValidUntil, operationData and validationData
     * @return true if the rebase operation succeeds
     * @dev Decodes the rebaseData and calls the rebase function on the NavWithRebase module
     * @dev rebaseData must be encoded as (uint256, uint256, bytes)
     */
    function rebase(bytes calldata rebaseData) public returns (bool) {
        // decode the data
        (uint256 newTotalAssets, uint256 rebaseValidUntil, bytes memory operationData, bytes memory validationData) =
            abi.decode(rebaseData, (uint256, uint256, bytes, bytes));

        rebasingNavModule.rebase(newTotalAssets, rebaseValidUntil, operationData, validationData);

        return true;
    }
}
