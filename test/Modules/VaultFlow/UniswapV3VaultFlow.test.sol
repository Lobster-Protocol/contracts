// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {UniswapV3VaultOperationsSetup} from "../../Vault/VaultSetups/WithRealModules/UniswapV3VaultOperationsSetup.sol";
import {INonFungiblePositionManager} from "../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultFlowModule} from "../../../src/interfaces/modules/IVaultFlowModule.sol";
import {UniswapV3VaultFlow} from "../../../src/Modules/VaultFlow/UniswapV3WithTwap.sol";
import {DeployUniV3} from "../../Mocks/uniswapV3/uniswapV3Factory.sol";

contract UniswapV3VaultOperations is UniswapV3VaultOperationsSetup, DeployUniV3 {
    // function testDeposit() public {
    //     vm.startPrank(alice);
    //     uint256 initialAliceAssetBalance = IERC20(vault.asset()).balanceOf(
    //         alice
    //     );
    //     uint256 initialVaultAssetBalance = IERC20(vault.asset()).balanceOf(
    //         address(vault)
    //     );

    //     // alice deposit
    //     uint256 depositedAmount = 1 ether;
    //     uint256 expectedShares = vault.convertToShares(depositedAmount);
    //     // ensure the deposit event is emitted
    //     vm.expectEmit(true, true, true, true);
    //     emit IERC4626.Deposit(alice, alice, depositedAmount, expectedShares);
    //     vault.deposit(depositedAmount, alice);

    //     vm.stopPrank();

    //     // ensure the transfer happened
    //     vm.assertEq(
    //         IERC20(vault.asset()).balanceOf(alice),
    //         initialAliceAssetBalance - depositedAmount
    //     );
    //     vm.assertEq(
    //         IERC20(vault.asset()).balanceOf(address(vault)),
    //         initialVaultAssetBalance + depositedAmount
    //     );
    // }

    // function testDepositHighVolatility() public {
    //     // todo
    // }

    // function testWithdraw() public {
    //     IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));
    //     vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     revert("voluntary revert");
    // }

    // function testWithdrawWithHighVolatilityAndNoWithdrawerAdvantage() public {
    //     // IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultOperations()));
    //     // vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     // revert("voluntary revert");
    // }

    // function testWithdrawWithHighVolatilityAndWithdrawerAdvantage() public {
    //     // IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultOperations()));
    //     // vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     // revert("voluntary revert");
    // }

    // function testTotalAssets()

    function testTotalAssetsFor() public {
        // /* ------ test deploy uniswap ------ */
        // (IUniswapV3FactoryMinimal factory, INonFungiblePositionManager positionManager) = deploy();

        // console.log("deployed factory: ", address(factory));
        // console.log("deployed position manager: ", address(positionManager));

        /* ------ test total assets for ------ */
        // uint256 expectedTotalAssets = 0;
        // uint256 totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        // assertEq(totalAsset, expectedTotalAssets);

        revert("volontary revert");
    }
}
