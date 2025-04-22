// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IVaultOperations} from "../../interfaces/modules/IVaultOperations.sol";
import {INav} from "../../interfaces/modules/INav.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// import {IUniswapV3PoolMinimal} from "../../interfaces/IUniswapV3PoolMinimal.sol";
import {BaseOp, Op} from "../../interfaces/modules/IOpValidatorModule.sol";
// import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";

uint256 constant BASIS_POINT_SCALE = 10_000;

// Hook used to take a fee when the vault collect its fees from a uniswap pool
contract UniswapV3VaultOperations is IVaultOperations, INav {
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        LobsterVault vault = LobsterVault(msg.sender);

        // transfer before minting to avoid reentrancy
        vault.safeTransferFrom(IERC20(vault.asset()), caller, address(vault), assets);
        vault.mintShares(receiver, shares);

        emit IERC4626.Deposit(caller, receiver, assets, shares);

        return true;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        // if the vault does not own the assets, transfer them to the vault
        // user withdraws the 2 tokens from the uniswap pool
        // the, a wrapper can be used to swap the tokens, leaving the user with only 1 token
    }

    function totalAssets() external view returns (uint256) {
        // use twap ? (observe on uniswapV3 & getTimepoints on algebra pools)
        // https://blog.uniswap.org/uniswap-v3-oracles
    }
}
