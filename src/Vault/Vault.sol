// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE} from "./Constants.sol";
import {Modular} from "../Modules/Modular.sol";
import {IHook} from "../interfaces/modules/IHook.sol";
import {INav} from "../interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import "../../src/interfaces/modules/IVaultFlowModule.sol";

/**
 * @title LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault with fee mechanisms and operation validation
 * @dev This contract combines ERC4626 tokenized vault standard with custom modules
 *      for operation validation, asset valuation, and deposit/withdraw flow control
 */
contract LobsterVault is Modular {
    using Math for uint256;

    /**
     * @notice Thrown when a zero address is provided for a critical parameter
     */
    error ZeroAddress();

    /**
     * @notice Constructs a new LobsterVault
     * @param initialOwner The address that will own the vault
     * @param asset The ERC20 token used by the vault
     * @param underlyingTokenName The name for the vault's share token
     * @param underlyingTokenSymbol The symbol for the vault's share token
     * @param opValidator_ The operation validator module
     * @param hook_ The hook module for pre/post operation execution
     * @param navModule_ The NAV module for asset valuation
     * @param vaultFlowModule The module for deposit/withdraw operations
     */
    constructor(
        address initialOwner,
        IERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        IOpValidatorModule opValidator_,
        IHook hook_,
        INav navModule_,
        IVaultFlowModule vaultFlowModule
    )
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (address(opValidator_) == address(0) && address(hook) != address(0)) {
            revert("Cannot install hook if there is no op validator");
        }

        if (vaultFlowModule != IVaultFlowModule(address(0))) {
            vaultFlowOverridePolicy = vaultFlowModule.overridePolicy();
        } else {
            vaultFlowOverridePolicy = 0;
        }

        opValidator = opValidator_;
        emit OpValidatorSet(opValidator_);

        hook = hook_;
        emit HookSet(hook_);

        navModule = navModule_;
        emit NavModuleSet(navModule_);

        vaultFlow = vaultFlowModule;
        emit vaultFlowSet(vaultFlowModule, vaultFlowOverridePolicy);
    }

    /* ------------------INAV------------------- */

    /**
     * @notice Returns the total assets managed by the vault
     * @dev Override ERC4626.totalAssets to use the NAV module if available
     * @return The total amount of underlying assets
     */
    function totalAssets() public view virtual override returns (uint256) {
        if (address(navModule) != address(0)) {
            return navModule.totalAssets();
        }
        return IERC20(asset()).balanceOf(address(this));
    }

    /* ------------------FLOW MODULE OVERRIDES------------------ */
    /**
     * @notice Handles the deposit logic
     * @dev Override of ERC4626._deposit to use the vaultFlow module if available
     * @param caller The address initiating the deposit
     * @param receiver The address receiving the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to mint
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        console.log("in _deposit");
        if (vaultFlowOverridePolicy & _DEPOSIT_OVERRIDE_ENABLED != 0) {
            console.log("in custom deposit");

            (bool success,) =
                address(vaultFlow).call(abi.encodeCall(vaultFlow._deposit, (caller, receiver, assets, shares)));

            if (!success) revert DepositModuleFailed();

            return;
        }

        console.log("in default deposit");

        // if no module set, backoff to default
        return super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Handles the withdrawal logic
     * @dev Override of ERC4626._withdraw to use the vaultFlow module if available
     * @param caller The address initiating the withdrawal
     * @param receiver The address receiving the assets
     * @param owner The address that owns the shares
     * @param assets The amount of assets to withdraw
     * @param shares The amount of shares to burn
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
    {
        if (vaultFlowOverridePolicy & _WITHDRAW_OVERRIDE_ENABLED != 0) {
            (bool success,) =
                address(vaultFlow).call(abi.encodeCall(vaultFlow._withdraw, (caller, receiver, owner, assets, shares)));

            if (!success) revert WithdrawModuleFailed();

            return;
        }

        // if no module set, backoff to default
        return super._withdraw(caller, receiver, owner, assets, shares);
    }

    function maxDeposit(address receiver) public view override returns (uint256 maxAssets) {
        console.log("in maxDeposit");
        if (vaultFlowOverridePolicy & MAX_DEPOSIT_OVERRIDE_ENABLED != 0) {
            console.log("in custom maxDeposit");
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.maxDeposit, (receiver)));

            if (!success) revert MaxDepositModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256 maxShares) {
        if (vaultFlowOverridePolicy & MAX_MINT_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.maxMint, receiver));

            if (!success) revert MaxMintModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256 maxAssets) {
        if (vaultFlowOverridePolicy & MAX_WITHDRAW_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.maxWithdraw, (owner)));

            if (!success) revert MaxWithdrawModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256 maxShares) {
        if (vaultFlowOverridePolicy & MAX_REDEEM_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.maxRedeem, (owner)));

            if (!success) revert MaxRedeemModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.maxRedeem(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        if (vaultFlowOverridePolicy & PREVIEW_DEPOSIT_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.previewDeposit, (assets)));

            if (!success) revert PreviewDepositModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.previewDeposit(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        if (vaultFlowOverridePolicy & PREVIEW_MINT_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.previewMint, (shares)));

            if (!success) revert PreviewMintModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.previewMint(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        if (vaultFlowOverridePolicy & PREVIEW_WITHDRAW_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.previewWithdraw, (assets)));

            if (!success) revert PreviewWithdrawModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        if (vaultFlowOverridePolicy & PREVIEW_REDEEM_OVERRIDE_ENABLED != 0) {
            (bool success, bytes memory data) =
                address(vaultFlow).staticcall(abi.encodeCall(vaultFlow.previewRedeem, (shares)));

            if (!success) revert PreviewRedeemModuleFailed();

            return abi.decode(data, (uint256));
        }

        return super.previewRedeem(shares);
    }

    /**
     * @notice Mints shares to an account
     * @param account The address to receive the shares
     * @param value The amount of shares to mint
     * @dev Can only be called by the vaultFlow module
     */
    function mintShares(address account, uint256 value) external OnlyVaultFlow {
        if (vaultFlowOverridePolicy & _DEPOSIT_OVERRIDE_ENABLED != 0) {
            return super._mint(account, value);
        }

        revert("Cannot mint shares if no module set & _deposit override not enabled");
    }

    /**
     * @notice Burns shares from an account
     * @param account The address to burn shares from
     * @param value The amount of shares to burn
     * @dev Can only be called by the vaultFlow module
     */
    function burnShares(address account, uint256 value) external OnlyVaultFlow {
        if (vaultFlowOverridePolicy & _WITHDRAW_OVERRIDE_ENABLED != 0) {
            return super._burn(account, value);
        }

        revert("Cannot burn shares if no module set & _withdraw override not enabled");
    }

    /**
     * @notice Approves a spender to spend a specified amount of tokens
     * @param owner The address that owns the tokens
     * @param spender The address that will be allowed to spend the tokens
     * @param value The amount of tokens to approve
     * @dev Can only be called by the vaultFlow module
     */
    function spendAllowance(address owner, address spender, uint256 value) external OnlyVaultFlow {
        if (vaultFlowOverridePolicy & _SPEND_ALLOWANCE_OVERRIDE_ENABLED != 0) {
            return super._spendAllowance(owner, spender, value);
        }
        _spendAllowance(owner, spender, value);
    }
}
