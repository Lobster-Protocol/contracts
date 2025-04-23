// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC4626Fees} from "./ERC4626Fees.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE} from "./Constants.sol";
import {Modular} from "../Modules/Modular.sol";
import {IHook} from "../interfaces/modules/IHook.sol";
import {INav} from "../interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import {IVaultOperations} from "../../src/interfaces/modules/IVaultOperations.sol";

contract LobsterVault is Modular, ERC4626Fees {
    using Math for uint256;

    bool private _executingOps;

    event FeesCollected(uint256 total, uint256 managementFees, uint256 performanceFees, uint256 timestamp);

    error ZeroAddress();

    // this modifier ensures a hook cannot call the vault by itself. Without having been called
    modifier inExecutionContext() {
        if (msg.sender == address(hook)) {
            // if the caller is the hook, only check if the call is allowed
            require(_executingOps, "Not allowed Hook call");
            _;
        } else {
            _executingOps = true;
            _;
            _executingOps = false;
        }
    }

    modifier OnlyVaultOperations() {
        require(msg.sender == address(vaultOperations), "Not allowed VaultOperations call");
        _;
    }

    // todo: add initial fees
    constructor(
        address initialOwner,
        IERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        address initialFeeCollector,
        IOpValidatorModule opValidator_,
        IHook hook_,
        INav navModule_,
        IVaultOperations vaultOperationsModule
    )
        Ownable(initialOwner)
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
        ERC4626Fees(initialFeeCollector)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (address(opValidator_) == address(0) && address(hook) != address(0)) {
            revert("Cannot install hook if there is no op validator");
        }

        opValidator = opValidator_;
        emit OpValidatorSet(opValidator_);

        hook = hook_;
        emit HookSet(hook_);

        navModule = navModule_;
        emit NavModuleSet(navModule_);

        vaultOperations = vaultOperationsModule;
        emit VaultOperationsSet(vaultOperationsModule);
    }

    /* ------------------SETTERS------------------ */

    /**
     * Override ERC4626.totalAssets
     * Returns the total assets managed by the Vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        if (address(navModule) != address(0)) {
            return navModule.totalAssets();
        }
        return IERC20(asset()).balanceOf(address(this));
    }

    /* ------------------FUNCTIONS FOR CUSTOM CALLS------------------ */

    function executeOp(Op calldata op) external inExecutionContext {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Skip validation if caller is the hook
        bool isFromHook = msg.sender == address(hook);

        // Validate operation if not from hook
        if (!isFromHook && !opValidator.validateOp(op)) {
            revert OpNotApproved();
        }

        // Execute operation with hook calls only if not from hook
        bytes memory ctx;
        if (!isFromHook) {
            ctx = _preCallHook(op.base, msg.sender);
        }

        _call(op.base);

        if (!isFromHook) {
            _postCallHook(ctx);
        }
    }

    function executeOpBatch(BatchOp calldata batch) external inExecutionContext {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Validate batch operation
        if (!opValidator.validateBatchedOp(batch)) {
            revert OpNotApproved();
        }

        // Check if caller is the hook
        bool isFromHook = msg.sender == address(hook);

        // Process all operations in batch
        uint256 length = batch.ops.length;
        for (uint256 i = 0; i < length;) {
            // Execute operation with hook calls only if not from hook
            bytes memory ctx;
            if (!isFromHook) {
                // todo: would it be better to call the hook once ? (but les granularity)
                ctx = _preCallHook(batch.ops[i], msg.sender);
            }

            _call(batch.ops[i]);

            if (!isFromHook) {
                _postCallHook(ctx);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _call(BaseOp calldata op) private {
        (bool success, bytes memory result) = op.target.call{value: op.value}(op.data);

        assembly {
            if iszero(success) { revert(add(result, 32), mload(result)) }
        }

        bytes4 selector;
        if (op.data.length > 4) {
            selector = bytes4(op.data[:4]);
        }

        emit Executed(op.target, op.value, selector);
    }

    /* ------------------HOOKS------------------- */
    /**
     * Calls the preCheck function from the Hook contract (if set)
     * @param op - the op to execute
     * @param caller - the address of the caller
     */
    function _preCallHook(BaseOp memory op, address caller) private returns (bytes memory context) {
        if (address(hook) != address(0)) {
            // Prepare the call data for preCheck function
            bytes memory callData = abi.encodeWithSelector(hook.preCheck.selector, op, caller);

            // Perform low-level static call
            (bool success, bytes memory returnData) = address(hook).call(callData);

            // Revert with PreHookFailed error if the call fails
            if (!success) {
                revert PreHookFailed();
            }

            return abi.decode(returnData, (bytes)); // decode the output
        }

        return "";
    }

    /**
     * Calls the postCheck function from the Hook contract (if set)
     * @param ctx - the context returned by _preCallHook
     */
    function _postCallHook(bytes memory ctx) private returns (bool success) {
        if (ctx.length > 0) {
            // Prepare the call data for preCheck function
            bytes memory callData = abi.encodeWithSelector(hook.postCheck.selector, ctx);

            // Perform low-level static call
            (bool callSuccess,) = address(hook).call(callData);

            // Revert with PreHookFailed error if the call fails
            if (!callSuccess) {
                revert PostHookFailed();
            }

            return true;
        }

        return true;
    }

    /* ------------------DEPOSIT & WITHDRAW MODULES------------------ */
    /**
     * Override of ERC4626._deposit
     * Calls the vaultOperations module
     * If no vaultOperations module is set, use the "default" one (ERC4626._deposit)
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (address(vaultOperations) != address(0)) {
            (bool success,) = address(vaultOperations).call(
                abi.encodeWithSelector(vaultOperations._deposit.selector, caller, receiver, assets, shares)
            );

            if (!success) revert DepositModuleFailed();

            return;
        }

        // if no module set, backoff to default
        return super._deposit(caller, receiver, assets, shares);
    }

    /**
     * Override of ERC4626._withdraw
     * Calls to the vaultOperations module
     * If no vaultOperations module is set, use the "default" one (ERC4626._withdraw)
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
        if (address(vaultOperations) != address(0)) {
            (bool success,) = address(vaultOperations).delegatecall(
                abi.encodeWithSelector(vaultOperations._withdraw.selector, caller, receiver, owner, assets, shares)
            );

            if (!success) revert WithdrawModuleFailed();

            return;
        }

        // if no module set, backoff to default
        return super._withdraw(caller, receiver, owner, assets, shares);
    }

    function mintShares(address account, uint256 value) external OnlyVaultOperations {
        return super._mint(account, value);
    }

    function burnShares(address account, uint256 value) external OnlyVaultOperations {
        return super._burn(account, value);
    }

    function safeTransfer(IERC20 token, address to, uint256 amount) external OnlyVaultOperations {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransfer(token, to, amount);
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) external OnlyVaultOperations {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransferFrom(token, from, to, amount);
    }
}
