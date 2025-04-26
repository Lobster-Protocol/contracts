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
import {IVaultFlowModule} from "../../src/interfaces/modules/IVaultFlowModule.sol";

/**
 * @title LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault with fee mechanisms and operation validation
 * @dev This contract combines ERC4626 tokenized vault standard with custom modules
 *      for operation validation, asset valuation, and deposit/withdraw flow control
 */
contract LobsterVault is Modular, ERC4626Fees {
    using Math for uint256;

    /**
     * @dev Used to protect the vault from hooks calls when the vault did not call it first
     * @notice Flag to track if the vault is currently executing operations
     */
    bool private _executingOps;

    /**
     * @notice Thrown when a zero address is provided for a critical parameter
     */
    error ZeroAddress();

    /**
     * @notice Ensures hook calls to the vault are properly authorized
     * @dev Used to protect the vault from hooks calls when the vault did not call it first
     */
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

    /**
     * @notice Ensures only the vaultFlow module can call the function
     * @dev Restricts access to certain functions that should only be accessed by the vaultFlow module
     */
    modifier OnlyVaultFlow() {
        require(msg.sender == address(vaultFlow), "Not allowed vaultFlow call");
        _;
    }

    /**
     * @notice Constructs a new LobsterVault
     * @param initialOwner The address that will own the vault
     * @param asset The ERC20 token used by the vault
     * @param underlyingTokenName The name for the vault's share token
     * @param underlyingTokenSymbol The symbol for the vault's share token
     * @param initialFeeCollector The address that will receive collected fees
     * @param opValidator_ The operation validator module
     * @param hook_ The hook module for pre/post operation execution
     * @param navModule_ The NAV module for asset valuation
     * @param vaultFlowModule The module for deposit/withdraw operations
     * @param entryFeeBasisPoints_ The initial entry fee in basis points
     * @param exitFeeBasisPoints_ The initial exit fee in basis points
     * @param managementFeeBasisPoints_ The initial management fee in basis points
     */
    constructor(
        address initialOwner,
        IERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        address initialFeeCollector,
        IOpValidatorModule opValidator_,
        IHook hook_,
        INav navModule_,
        IVaultFlowModule vaultFlowModule,
        uint16 entryFeeBasisPoints_,
        uint16 exitFeeBasisPoints_,
        uint16 managementFeeBasisPoints_
    )
        Ownable(initialOwner)
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
        ERC4626Fees(initialFeeCollector, entryFeeBasisPoints_, exitFeeBasisPoints_, managementFeeBasisPoints_)
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

        vaultFlow = vaultFlowModule;
        emit vaultFlowSet(vaultFlowModule);
    }

    /* ------------------FUNCTIONS FOR CUSTOM CALLS------------------ */

    /**
     * @notice Executes a single operation after validation
     * @param op The operation to execute
     * @dev Requires an operation validator to be set
     * @dev If called by a hook, validation is skipped but operations are still executed
     */
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

    /**
     * @notice Executes a batch of operations after validation
     * @param batch The batch operation containing multiple operations
     * @dev Requires an operation validator to be set
     * @dev If called by a hook, hook validation is skipped but operations are still executed
     */
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

    /**
     * @notice Internal function to perform the actual call in an operation
     * @param op The base operation containing target, value, and data
     * @dev Emits an Executed event after successful execution
     */
    function _call(BaseOp calldata op) private {
        (bool success, bytes memory result) = op.target.call{value: op.value}(op.data);

        assembly {
            if iszero(success) { revert(add(result, 32), mload(result)) }
        }

        bytes4 selector = bytes4(0);
        if (op.data.length > 4) {
            selector = bytes4(op.data[:4]);
        }

        emit Executed(op.target, op.value, selector);
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

    /* ------------------HOOKS------------------- */
    /**
     * @notice Calls the preCheck function from the Hook contract (if set)
     * @param op The operation to execute
     * @param caller The address of the caller
     * @return context Data to be passed to the postCheck function
     * @dev Reverts with PreHookFailed if the hook's preCheck fails
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
     * @notice Calls the postCheck function from the Hook contract (if set)
     * @param ctx The context returned by _preCallHook
     * @return success True if the post hook was successful or not needed
     * @dev Reverts with PostHookFailed if the hook's postCheck fails
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
     * @notice Handles the deposit logic
     * @dev Override of ERC4626._deposit to use the vaultFlow module if available
     * @param caller The address initiating the deposit
     * @param receiver The address receiving the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to mint
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (address(vaultFlow) != address(0)) {
            (bool success,) = address(vaultFlow).call(
                abi.encodeWithSelector(vaultFlow._deposit.selector, caller, receiver, assets, shares)
            );

            if (!success) revert DepositModuleFailed();

            return;
        }

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
        if (address(vaultFlow) != address(0)) {
            (bool success,) = address(vaultFlow).call(
                abi.encodeWithSelector(vaultFlow._withdraw.selector, caller, receiver, owner, assets, shares)
            );

            if (!success) revert WithdrawModuleFailed();

            return;
        }

        // if no module set, backoff to default
        return super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @notice Mints shares to an account
     * @param account The address to receive the shares
     * @param value The amount of shares to mint
     * @dev Can only be called by the vaultFlow module
     */
    function mintShares(address account, uint256 value) external OnlyVaultFlow {
        return super._mint(account, value);
    }

    /**
     * @notice Burns shares from an account
     * @param account The address to burn shares from
     * @param value The amount of shares to burn
     * @dev Can only be called by the vaultFlow module
     */
    function burnShares(address account, uint256 value) external OnlyVaultFlow {
        return super._burn(account, value);
    }

    /**
     * @notice Safely transfers tokens to an address
     * @param token The ERC20 token to transfer
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev Can only be called by the vaultFlow module
     */
    function safeTransfer(IERC20 token, address to, uint256 amount) external OnlyVaultFlow {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransfer(token, to, amount);
    }

    /**
     * @notice Safely transfers tokens from one address to another
     * @param token The ERC20 token to transfer
     * @param from The source address
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev Can only be called by the vaultFlow module
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) external OnlyVaultFlow {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransferFrom(token, from, to, amount);
    }
}
