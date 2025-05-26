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
 * erc4626 vault with operation validation module
 */
contract ERC4626WithOpValidator is Modular {
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
    }
}
