// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {UniV3LobsterVaultFeesSetup} from "../Vault/VaultSetups/WithRealModules/UniswapV3VaultFeesSetup.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../Mocks/MockERC20.sol";

contract UniswapV3VaultTest is UniV3LobsterVaultFeesSetup {
    function testPreviewMaxWithdrawMatchesPreviewWithdrawNoPositionsFees() public {
        // Alice deposits
        uint256 depositedAmount0 = 1 ether;
        uint256 depositedAmount1 = 3 ether;

        uint256 mintedShares = depositToVault(alice, depositedAmount0, depositedAmount1);

        // Convert the max withdrawable amount to shares
        uint256 maxRedeemResult = vault.maxRedeem(alice);

        // Convert the shares to assets
        uint256 previewMaxRedeemResultAssets = vault.convertToAssets(maxRedeemResult);

        // Ensure minted shares are the max we could withdraw (after the conversions)
        vm.assertEq(maxRedeemResult, mintedShares);

        // Ensure the max withdrawable asset amount is the same as the deposit
        vm.assertEq(previewMaxRedeemResultAssets, packUint128(uint128(depositedAmount0), uint128(depositedAmount1) - 2)); // -2 because of the rounding errors
    }

    function testPreviewMaxWithdrawMatchesPreviewWithdrawPositionsFees() public {
        uint256 amountA = 10_000 ether;
        uint256 amountB = 10_000 ether;
        // mint some tokens for the test
        MockERC20(uniswapV3Data.tokenA).mint(bob, amountA); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(bob, amountB); // 1000 tokens with 18 decimals

        createPosition(
            uniswapV3Data.positionManager,
            uniswapV3Data.tokenA,
            uniswapV3Data.tokenB,
            amountA,
            amountB,
            uniswapV3Data.poolFee,
            bob
        );

        vm.stopPrank();

        // Alice deposits 1 ether into the vault
        uint256 aliceDeposit0 = 1 ether;
        uint256 aliceDeposit1 = 1 ether; // First depositor can deposit the ratio they want
        depositToVault(alice, aliceDeposit0, aliceDeposit1);

        // get both token amounts
        uint256 tokenAInVaultAfterSwap = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 tokenBInVaultAfterSwap = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault)); // expected to be <= aliceDeposit/2 because of the slippage

        // allow the position manager to spend the tokens
        vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));
        vaultOpApproveToken(uniswapV3Data.tokenB, address(uniswapV3Data.positionManager));

        // Create a new position with the swapped tokens
        vaultOpMintUniswapPosition(
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenAInVaultAfterSwap : tokenBInVaultAfterSwap,
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenBInVaultAfterSwap : tokenAInVaultAfterSwap,
            -6000,
            6000,
            100
        );

        uint256 value = 12345689;
        // keep the 1:1 ratio
        uint256 packedValue = packUint128(uint128(value), uint128(value));

        uint256 previewDeposit = vault.previewDeposit(packedValue);
        uint256 previewRedeem = vault.previewRedeem(previewDeposit);

        (uint256 previewRedeem0, uint256 previewRedeem1) = decodePackedUint128(previewRedeem);

        // accept 1 wei of error because of rounding
        vm.assertApproxEqAbs(previewRedeem0, value, 1);
        vm.assertApproxEqAbs(previewRedeem1, value, 1);

        uint256 previewMint = vault.previewMint(value); // assets
        uint256 previewWithdraw = vault.previewWithdraw(previewMint); // shares

        vm.assertApproxEqAbs(value, previewWithdraw, 1);
    }
}
