// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {UniV3LobsterVaultNoFeesSetup} from "../Vault/VaultSetups/WithRealModules/UniswapV3VaultFlowNoFeesSetup.sol";
import {MockERC20} from "../Mocks/MockERC20.sol";

contract UniswapV3VaultFlowTest is UniV3LobsterVaultNoFeesSetup {
    function testMaxWithdrawNoPositionsNoFees() public {
        // Alice deposits
        uint256 depositedAmount0 = 1 ether;
        uint256 depositedAmount1 = 3 ether;

        uint256 mintedShares = depositToVault(alice, depositedAmount0, depositedAmount1);

        uint256 maxWithdrawResult = maxWithdraw(alice);

        vm.assertEq(maxWithdrawResult, vault.previewRedeem(mintedShares));
    }

    function testMaxWithdrawWithPositionsNoFees() public {
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
        uint256 aliceDeposit1 = 3 ether;

        depositToVault(alice, aliceDeposit0, aliceDeposit1);
        // allow the position manager to spend the tokens
        vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));
        vaultOpApproveToken(uniswapV3Data.tokenB, address(uniswapV3Data.positionManager));

        // Create a new position with the swapped tokens
        vaultOpMintUniswapPosition(
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? aliceDeposit1 : aliceDeposit0,
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? aliceDeposit1 : aliceDeposit0,
            -6000,
            6000,
            100
        );

        maxWithdraw(alice);
        // vault.maxWithdraw result has been checked against the expected value in maxWithdraw()
    }

    function testMaxRedeemNoPositionsNoFees() public {
        // Alice deposits
        uint128 depositedAmount0 = 1 ether;
        uint128 depositedAmount1 = 3 ether;

        uint256 mintedShares = depositToVault(alice, depositedAmount0, depositedAmount1);

        uint256 maxRedeemResult = maxRedeem(alice);

        // No need to pack anything, the vault only contains the deposited amount. No other tokens
        vm.assertEq(maxRedeemResult, mintedShares);
    }

    function testRedeemWithPositionsNoFees() public {}

    // todo:
    // function testMaxWithdrawNoPositionsWithFees() public {}

    // function testMaxWithdrawWithPositionsWithFees() public {}
}
