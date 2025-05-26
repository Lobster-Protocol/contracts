// // SPDX-License-Identifier: GNUv3
// pragma solidity ^0.8.28;

// import {UniswapV3VaultFlowSetup} from "../../../Vault/VaultSetups/WithRealModules/UniswapV3VaultFlowSetup.sol";
// import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
// import {UniswapV3VaultFlow} from "../../../../src/Modules/VaultFlow/UniswapV3VaultFlow.sol";
// import {MockERC20} from "../../../Mocks/MockERC20.sol";

// contract UniswapV3VaultFlowTest is UniswapV3VaultFlowSetup {
//     function testPreviewMaxWithdrawMatchesPreviewWithdrawNoPositionsNoFees() public {
//         // Alice deposits
//         uint256 depositedAmount0 = 1 ether;
//         uint256 depositedAmount1 = 3 ether;

//         uint256 mintedShares = depositToVault(alice, depositedAmount0, depositedAmount1);

//         // Convert the max withdrawable amount to shares
//         uint256 maxRedeemResult = vault.maxRedeem(alice);

//         // Convert the shares to assets
//         uint256 previewMaxRedeemResultAssets = vault.convertToAssets(maxRedeemResult);

//         // Ensure minted shares are the max we could withdraw (after the conversions)
//         vm.assertEq(maxRedeemResult, mintedShares);

//         // Ensure the max withdrawable asset amount is the same as the deposit (since the vault does not have the second token)
//         vm.assertEq(previewMaxRedeemResultAssets, packUint128(uint128(depositedAmount0), uint128(depositedAmount1)));
//     }

//     function testPreviewMaxWithdrawMatchesPreviewWithdrawPositionsNoFees() public {
//         uint256 amountA = 10_000 ether;
//         uint256 amountB = 10_000 ether;
//         // mint some tokens for the test
//         MockERC20(uniswapV3Data.tokenA).mint(bob, amountA); // 1000 tokens with 18 decimals
//         MockERC20(uniswapV3Data.tokenB).mint(bob, amountB); // 1000 tokens with 18 decimals

//         createPosition(
//             uniswapV3Data.positionManager,
//             uniswapV3Data.tokenA,
//             uniswapV3Data.tokenB,
//             amountA,
//             amountB,
//             uniswapV3Data.poolFee,
//             bob
//         );

//         vm.stopPrank();

//         // Alice deposits 1 ether into the vault
//         uint256 aliceDeposit0 = 1 ether;
//         uint256 aliceDeposit1 = 1 ether; // First depositor can deposit the ratio they want
//         uint256 mintedShares = depositToVault(alice, aliceDeposit0, aliceDeposit1);

//         // get both token amounts
//         uint256 tokenAInVaultAfterSwap = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
//         uint256 tokenBInVaultAfterSwap = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault)); // expected to be <= aliceDeposit/2 because of the slippage

//         // allow the position manager to spend the tokens
//         vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));
//         vaultOpApproveToken(uniswapV3Data.tokenB, address(uniswapV3Data.positionManager));

//         // Create a new position with the swapped tokens
//         vaultOpMintUniswapPosition(
//             uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenAInVaultAfterSwap : tokenBInVaultAfterSwap,
//             uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenBInVaultAfterSwap : tokenAInVaultAfterSwap,
//             -6000,
//             6000,
//             100
//         );

//         uint256 maxWithdrawResult = maxWithdraw(alice);
//         (uint256 maxWithdrawable0, uint256 maxWithdrawable1) = decodePackedUint128(maxWithdrawResult);

//         bool isVaultAssetToken0 = vault.asset() == uniswapV3Data.tokenA;

//         // Convert the max withdrawable amount to shares
//         uint256 previewMaxWithdrawResult =
//             vault.previewWithdraw(isVaultAssetToken0 ? maxWithdrawable0 : maxWithdrawable1);

//         // Convert the shares to assets
//         vault.convertToAssets(previewMaxWithdrawResult);

//         // Ensure minted shares are the max we could withdraw (after the conversions)
//         vm.assertEq(previewMaxWithdrawResult, mintedShares);

//         // Ensure the max withdrawable asset amount is the same as the deposit
//         // vm.assertEq(previewMaxWithdrawResultAssets, aliceDeposit); // todo: get expected token 0 and token 1 amounts (see alexis for)
//     }
//     //
//     // function testPreviewMintMatchesPreviewMintNoPositionsNoFees() public {} // todo

//     // function testPreviewMintMatchesPreviewMintPositionsNoFees() public {} // todo

//     // function testPreviewDepositMatchesPreviewDepositNoPositionsNoFees()
//     //     public
//     // {} // todo

//     // function testPreviewDepositMatchesPreviewDepositPositionsNoFees() public {} // todo

//     // function testPreviewRedeemMatchesPreviewRedeemNoPositionsNoFees() public {} // todo

//     // function testPreviewRedeemMatchesPreviewRedeemPositionsNoFees() public {} // todo
// }
