// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {VaultWithOperationModuleTestSetup} from
    "../Vault/VaultSetups/WithDummyModules/VaultWithOperationModuleTestSetup.sol";
import {
    CALL_MINT_SHARES,
    CALL_BURN_SHARES,
    CALL_SAFE_TRANSFER,
    CALL_SAFE_TRANSFER_FROM
} from "../Mocks/modules/DummyVaultFlow.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IVaultFlowModule} from "../../src/interfaces/modules/IVaultFlowModule.sol";
import {DummyVaultFlow} from "../Mocks/modules/DummyVaultFlow.sol";
import {MockERC20} from "../Mocks/MockERC20.sol";

contract VaultOperationSpecificFcts is VaultWithOperationModuleTestSetup {
    function testMintSharesAsVaultFlow() public {
        uint256 initialTotalSharesSupply = vault.totalSupply();

        uint256 initialAliceSharesBalance = vault.balanceOf(alice);
        uint256 mintedShares = 1 ether;
        uint256 depositedAssets = vault.convertToAssets(mintedShares);

        IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));

        // setup the vault address in operations contract
        DummyVaultFlow(address(vaultOps)).setVault(address(vault));

        vaultOps._deposit(CALL_MINT_SHARES, alice, depositedAssets, mintedShares);

        // ensure the mint happened
        vm.assertEq(vault.balanceOf(alice), initialAliceSharesBalance + mintedShares);

        vm.assertEq(vault.totalSupply(), initialTotalSharesSupply + mintedShares);
    }

    function testMintSharesAsNotVaultFlow() public {
        vm.startPrank(alice); // not the vault operations contract
        uint256 mintedShares = 1 ether;

        vm.expectRevert("Not allowed vaultFlow call");
        vault.mintShares(alice, mintedShares);

        vm.stopPrank();
    }

    function testBurnSharesAsVaultFlow() public {
        // mint assets
        uint256 mintedShares = 1 ether;
        uint256 depositedAssets = vault.convertToAssets(mintedShares);

        IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));

        // setup the vault address in operations contract
        DummyVaultFlow(address(vaultOps)).setVault(address(vault));

        vaultOps._deposit(CALL_MINT_SHARES, alice, depositedAssets, mintedShares);

        // burn shares
        uint256 burnedShares = 0.5 ether;
        uint256 initialTotalSharesSupply = vault.totalSupply();

        uint256 initialAliceSharesBalance = vault.balanceOf(alice);

        vaultOps._deposit(CALL_BURN_SHARES, alice, 0, burnedShares);

        // ensure the burn happened
        vm.assertEq(vault.balanceOf(alice), initialAliceSharesBalance - burnedShares);

        vm.assertEq(vault.totalSupply(), initialTotalSharesSupply - burnedShares);
        vm.stopPrank();
    }

    function testBurnSharesAsNotVaultFlow() public {
        vm.startPrank(alice); // not the vault operations contract
        uint256 burnedShares = 1 ether;

        vm.expectRevert("Not allowed vaultFlow call");
        vault.burnShares(alice, burnedShares);

        vm.stopPrank();
    }

    function testSafeTransferAsVaultFlow() public {
        // mint some tokens to the vault
        MockERC20 token = new MockERC20();
        uint256 initialVaultTokens = 100 ether;
        token.mint(address(vault), initialVaultTokens);

        IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));

        // setup the vault address in operations contract
        DummyVaultFlow(address(vaultOps)).setVault(address(vault));
        DummyVaultFlow(address(vaultOps)).setToken(address(token));

        // transfer tokens from vault to alice
        uint256 initialAliceBalance = token.balanceOf(alice);
        uint256 transferAmount = 10 ether;
        vaultOps._deposit(CALL_SAFE_TRANSFER, alice, transferAmount, 0);

        // ensure the transfer happened
        vm.assertEq(token.balanceOf(alice), initialAliceBalance + transferAmount);
        vm.assertEq(token.balanceOf(address(vault)), initialVaultTokens - transferAmount);
    }

    function testSafeTransferAsNotVaultFlow() public {
        // mint some tokens to the vault
        MockERC20 token = new MockERC20();
        uint256 initialVaultTokens = 100 ether;
        token.mint(address(vault), initialVaultTokens);

        vm.startPrank(alice); // not the vault operations contract
        uint256 transferAmount = 10 ether;

        vm.expectRevert("Not allowed vaultFlow call");
        vault.safeTransfer(token, alice, transferAmount);

        vm.stopPrank();
    }

    function testSafeTransferFromAsVaultFlow() public {
        // mint some tokens to the vault
        MockERC20 token = new MockERC20();
        uint256 initialVaultTokens = 100 ether;
        token.mint(address(vault), initialVaultTokens);

        // IMPORTANT FIX: Mint tokens to the CALL_SAFE_TRANSFER_FROM address
        token.mint(CALL_SAFE_TRANSFER_FROM, 20 ether);

        vm.startPrank(CALL_SAFE_TRANSFER_FROM);
        // allow the vault to transfer tokens
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));

        // setup the vault address in operations contract
        DummyVaultFlow(address(vaultOps)).setVault(address(vault));
        DummyVaultFlow(address(vaultOps)).setToken(address(token));

        // transfer tokens from CALL_SAFE_TRANSFER_FROM to alice
        vm.startPrank(alice);
        uint256 initialAliceBalance = token.balanceOf(alice);
        uint256 transferAmount = 10 ether;
        token.approve(address(vault), transferAmount);

        // Get the initial balance of CALL_SAFE_TRANSFER_FROM
        uint256 initialCallerBalance = token.balanceOf(CALL_SAFE_TRANSFER_FROM);

        vaultOps._deposit(CALL_SAFE_TRANSFER_FROM, alice, transferAmount, 0);

        // ensure the transfer happened
        vm.assertEq(token.balanceOf(alice), initialAliceBalance + transferAmount);

        // Ensure tokens were taken from CALL_SAFE_TRANSFER_FROM
        vm.assertEq(token.balanceOf(CALL_SAFE_TRANSFER_FROM), initialCallerBalance - transferAmount);

        // Vault balance shouldn't change in a safeTransferFrom between other addresses
        vm.assertEq(token.balanceOf(address(vault)), initialVaultTokens);

        vm.stopPrank();
    }

    function testSafeTransferFromAsNotVaultFlow() public {
        // mint some tokens to the vault
        MockERC20 token = new MockERC20();
        uint256 initialVaultTokens = 100 ether;
        token.mint(address(vault), initialVaultTokens);

        vm.startPrank(CALL_SAFE_TRANSFER_FROM);
        // allow the vault to transfer tokens
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice); // not the vault operations contract
        uint256 transferAmount = 10 ether;

        vm.expectRevert("Not allowed vaultFlow call");
        vault.safeTransferFrom(token, alice, address(vault), transferAmount);

        vm.stopPrank();
    }
}
