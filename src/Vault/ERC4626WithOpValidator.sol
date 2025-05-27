// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {Modular} from "../Modules/Modular.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";

/**
 * @title ERC4626WithOpValidator
 * @author Lobster
 * @notice A standard ERC4626 vault extended with secure operation validation capabilities.
 * This vault can execute arbitrary external operations (like DeFi protocol interactions)
 * through a validation system that ensures only approved operations are executed.
 * @dev This contract combines:
 * - Standard ERC4626 vault functionality (deposit, withdraw, mint, redeem)
 * - Modular operation execution system with validator-based security
 * - Support for single operations and batched operations
 * - Custom ERC20 token naming for vault shares
 */
contract ERC4626WithOpValidator is Modular {
    /**
     * @notice Constructs a new ERC4626 vault with operation validation capabilities
     * @param receiptTokenName_ The human-readable name for the vault's share tokens (e.g., "Lobster USDC Vault")
     * @param receiptTokenSymbol_ The symbol for the vault's share tokens (e.g., "lUSDC")
     * @param asset_ The underlying ERC20 token that this vault accepts for deposits
     * @param opValidator_ The operation validator module that will approve/reject vault operations
     * @dev The validator cannot be the zero address as this would disable all operation execution,
     * making the extended functionality unusable. Standard ERC4626 functions (deposit, withdraw, etc.)
     * work independently of the validator.
     * @dev Emits OpValidatorSet event when the validator is successfully configured
     */
    constructor(
        string memory receiptTokenName_,
        string memory receiptTokenSymbol_,
        IERC20 asset_,
        IOpValidatorModule opValidator_
    )
        ERC20(receiptTokenName_, receiptTokenSymbol_)
        ERC4626(asset_)
    {
        if (address(opValidator_) == address(0)) {
            revert("ERC4626WithOpValidator: opValidator cannot be address(0)");
        }

        opValidator = opValidator_;
        emit OpValidatorSet(opValidator_);
    }
}
