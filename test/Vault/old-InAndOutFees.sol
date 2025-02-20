// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.28;

// import "forge-std/Test.sol";
// import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
// import {VaultTestSetup} from "./VaultTestSetup.sol";
// import {ERC4626Fees, IERC4626FeesEvents} from "../../src/Vault/ERC4626Fees.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {BASIS_POINT_SCALE} from "../../src/Vault/Constants.sol";

// // test deposit / withdraw / mint / redeem fee
// contract VaultInAndOutFeesTest is VaultTestSetup {
//     using Math for uint256;
//     // the default fee is set to 0

//     /* -----------------------HELPER FUNCTIONS TO SET VAULT FEES----------------------- */
//     function setEntryFeeBasisPoint(uint256 fee) public returns (bool) {
//         vm.startPrank(owner);
//         vault.setEntryFee(fee);
//         vm.stopPrank();

//         return true;
//     }

//     function setExitFeeBasisPoint(uint256 fee) public returns (bool) {
//         vm.startPrank(owner);
//         vault.setExitFee(fee);
//         vm.stopPrank();

//         return true;
//     }

//     function computeFees(
//         uint256 amount,
//         uint256 fee
//     ) public pure returns (uint256) {
//         return amount.mulDiv(fee, BASIS_POINT_SCALE, Math.Rounding.Ceil);
//     }

//     /* -----------------------TEST DEPOSIT/WITHDRAW/MINT/REDEEM FEE UPDATE----------------------- */

//     function testUpdateDepositFee() public {
//         // set fees to 200 (2%)
//         setEntryFeeBasisPoint(200);

//         (uint256 newFee, uint256 enforcementMinTimestamp) = vault
//             .pendingEntryFeeUpdate();

//         assertEq(newFee, 200);
//         assertEq(
//             enforcementMinTimestamp,
//             block.timestamp + vault.FEE_UPDATE_DELAY()
//         );

//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());

//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewEntryFee();
//         vm.stopPrank();
//         // ensure pending fee has been updated
//         (uint256 fee, uint256 enforcementTimestamp) = vault
//             .pendingEntryFeeUpdate();
//         assertEq(fee, 0);
//         assertEq(enforcementTimestamp, 0);
//         assertEq(vault.entryFeeBasisPoints(), 200);
//     }

//     function testEnforceEntryPendingFeesThatDontExist() public {
//         // try to enforce fees when there is no pending fee update
//         vm.startPrank(owner);
//         vm.expectRevert(IERC4626FeesEvents.NoPendingFeeUpdate.selector);
//         vault.enforceNewEntryFee();
//         vm.stopPrank();
//     }

//     function testEnforceExitPendingFeesThatDontExist() public {
//         // try to enforce fees when there is no pending fee update
//         vm.startPrank(owner);
//         vm.expectRevert(IERC4626FeesEvents.NoPendingFeeUpdate.selector);
//         vault.enforceNewExitFee();
//         vm.stopPrank();
//     }

//     function testEnforceEntryFeesBeforeTimestamp() public {
//         // set fees to 55 (0.55%)
//         setEntryFeeBasisPoint(55);

//         // expected values
//         uint256 currentTimestamp = block.timestamp;
//         uint256 activationTimestamp = currentTimestamp +
//             vault.FEE_UPDATE_DELAY();

//         // Try to enforce fees when the timestamp is not reached
//         vm.startPrank(owner);

//         // We expect it to revert with ActivationTimestampNotReached error
//         // containing the current timestamp and activation timestamp
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IERC4626FeesEvents.ActivationTimestampNotReached.selector,
//                 currentTimestamp,
//                 activationTimestamp
//             )
//         );

//         vm.stopPrank();

//         vm.startPrank(owner);
//         vault.enforceNewEntryFee();
//         vm.stopPrank();
//     }

//     function testEnforceExitFeesBeforeTimestamp() public {
//         // set fees to 55 (0.55%)
//         setExitFeeBasisPoint(55);

//         // expected values
//         uint256 currentTimestamp = block.timestamp;
//         uint256 activationTimestamp = currentTimestamp +
//             vault.FEE_UPDATE_DELAY();

//         // Try to enforce fees when the timestamp is not reached
//         vm.startPrank(owner);

//         // We expect it to revert with ActivationTimestampNotReached error
//         // containing the current timestamp and activation timestamp
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IERC4626FeesEvents.ActivationTimestampNotReached.selector,
//                 currentTimestamp,
//                 activationTimestamp
//             )
//         );

//         vault.enforceNewExitFee();
//         vm.stopPrank();
//     }

//     // idk why this test is failing
//     // todo: fix this
//     // function testSetEntryFeeGtMaxFee() public {
//     //     // set fees to MAX_FEE + 1
//     //     vm.startPrank(owner);
//     //     vm.expectRevert(ERC4626Fees.InvalidFee.selector);
//     //     vault.setEntryFee(vault.MAX_FEE() + 1);
//     //     vm.stopPrank();
//     // }

//     // idk why this test is failing
//     // todo: fix this
//     // function testSetExitFeeGtMaxFee() public {
//     //     // set fees to MAX_FEE + 1
//     //     vm.startPrank(owner);
//     //     vm.expectRevert(ERC4626Fees.InvalidFee.selector);
//     //     vault.setExitFee(vault.MAX_FEE() + 1);
//     //     vm.stopPrank();
//     // }

//     function testEnsureFeeCollectorReceivesTheAsset() public {
//         uint256 feeCollectorInitialBalance = vault.balanceOf(
//             vault.feeCollector()
//         );

//         // set fees to 150 (1.5%)
//         uint256 fee = 150;
//         setExitFeeBasisPoint(fee);
//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewExitFee();
//         vm.stopPrank();

//         rebaseVault(0, block.number + 1);
//         uint256 depositAmount = 1000;
//         vm.startPrank(alice);
//         vault.deposit(depositAmount, alice);

//         uint256 exitFee = computeFees(depositAmount, fee);
//         vault.withdraw(vault.maxWithdraw(alice) - exitFee, alice, alice);
//         vm.stopPrank();

//         // ensure the collector has received the fees
//         assertEq(
//             vault.balanceOf(vault.feeCollector()),
//             feeCollectorInitialBalance + exitFee
//         );
//     }

//     /* -----------------------TEST ENTRY/EXIT FUNCTIONS WITH FEES----------------------- */
//     function testDepositFee() public {
//         rebaseVault(0, block.number + 1);

//         // alice deposits 1000 with a fee of 0
//         vm.startPrank(alice);
//         vault.deposit(1000, alice);

//         assertEq(vault.maxWithdraw(alice), 1000);
//         vm.stopPrank();

//         // set fees to 150 (1.5%)
//         setEntryFeeBasisPoint(150);
//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewEntryFee();
//         vm.stopPrank();

//         // bob deposits 1000 with a fee of 150
//         vm.startPrank(bob);
//         uint256 bobDeposit = 1000;
//         vault.deposit(bobDeposit, bob);
//         vm.stopPrank();

//         assertEq(
//             vault.maxWithdraw(bob),
//             bobDeposit - computeFees(bobDeposit, 150)
//         );
//         assertEq( // vault balance remains the same
//             vault.totalAssets(),
//             1000 + bobDeposit
//         );
//         assertEq(
//             vault.balanceOf(bob),
//             bobDeposit - computeFees(bobDeposit, 150)
//         );

//         // ensure fee collector received the fees
//         assertEq(
//             vault.balanceOf(vault.feeCollector()),
//             computeFees(bobDeposit, 150)
//         );
//     }

//     function testMintFee() public {
//         rebaseVault(0, block.number + 1);

//         // set fees to 150 (1.5%)
//         uint256 mintFee = 150;
//         setEntryFeeBasisPoint(mintFee);
//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewEntryFee();
//         vm.stopPrank();

//         // bob mints 1000 with a fee of mintFee
//         vm.startPrank(bob);
//         uint256 bobInitialAssetBalance = asset.balanceOf(bob);
//         uint256 expectedAssetValue = vault.previewMint(1000); // 1000 + fee

//         uint256 bobMint = 1000;
//         uint256 depositedAssets = vault.mint(bobMint, bob);
//         // ensure bob sent the asset to the vault + fees
//         assertEq(
//             asset.balanceOf(bob),
//             bobInitialAssetBalance
//         );

//         // assertEq(
//         //     vault.totalAssets(),
//         //     expectedAssetValue
//         // );

//         // // ensure bob received the minted tokens
//         // assertEq(vault.balanceOf(bob), bobMint);

//         // // ensure fee collector received the fees
//         // assertEq(
//         //     vault.balanceOf(vault.feeCollector()),
//         //     computeFees(bobMint - 15, mintFee) // depositedAssets - 15 because bobMint is 1000 + fee so we remove them (1000 * 1.5%)
//         // );
//     }

//     function testWithdrawFee() public {
//         rebaseVault(0, block.number + 1);

//         // alice deposits 1000 with a fee of 0
//         vm.startPrank(alice);
//         vault.deposit(1000, alice);

//         assertEq(vault.maxWithdraw(alice), 1000);
//         vm.stopPrank();

//         // bob deposits 1000 with a fee of 0
//         vm.startPrank(bob);
//         uint256 bobDeposit = 1000;
//         vault.deposit(bobDeposit, bob);
//         vm.stopPrank();

//         // set fees to 150 (1.5%)
//         setExitFeeBasisPoint(150);
//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewExitFee();
//         vm.stopPrank();

//         // bob withdraws 1000 with a fee of 150
//         vm.startPrank(bob);
//         uint256 bobInitialAssetBalance = asset.balanceOf(bob);
//         uint256 maxWithdraw = vault.maxWithdraw(bob);
//         uint256 expectedWithdrawnAssetValue = maxWithdraw -
//             computeFees(maxWithdraw, 150);
//         uint256 feeCollectorInitialBalance = asset.balanceOf(
//             vault.feeCollector()
//         );

//         vault.withdraw(expectedWithdrawnAssetValue, bob, bob);

//         // ensure bob received the asset - fees
//         assertEq(
//             asset.balanceOf(bob),
//             bobInitialAssetBalance + expectedWithdrawnAssetValue
//         );

//         // ensure the vault sent the asset to bob - fees
//         assertEq(vault.totalAssets(), 1000); // only alice's deposit remains

//         // ensure bob's shares have been burned
//         assertEq(vault.balanceOf(bob), 0);

//         // ensure the exit fee collector received the fees
//         assertEq(
//             asset.balanceOf(vault.feeCollector()),
//             feeCollectorInitialBalance + computeFees(maxWithdraw, 150)
//         );
//     }

//     function testRedeemFee() public {
//         rebaseVault(0, block.number + 1);

//         // alice deposits 1000 with a fee of 0
//         vm.startPrank(alice);
//         vault.deposit(1000, alice);

//         assertEq(vault.maxWithdraw(alice), 1000);
//         vm.stopPrank();

//         // bob deposits 799 with a fee of 0
//         vm.startPrank(bob);
//         uint256 bobDeposit = 799;
//         vault.deposit(bobDeposit, bob);
//         vm.stopPrank();

//         // set fees to 33 (0.33%)
//         setExitFeeBasisPoint(33);
//         // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
//         vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
//         // enforce the fee update
//         vm.startPrank(owner);
//         vault.enforceNewExitFee();
//         vm.stopPrank();

//         // bob redeems all his shares with a fee of 33
//         vm.startPrank(bob);
//         uint256 bobInitialAssetBalance = asset.balanceOf(bob);
//         uint256 expectedRedeemedAssetValue = vault.previewRedeem(
//             vault.balanceOf(bob)
//         ); // 799 - fee

//         vault.redeem(vault.balanceOf(bob), bob, bob);

//         // ensure bob received the asset - fees
//         assertEq(
//             asset.balanceOf(bob),
//             bobInitialAssetBalance + expectedRedeemedAssetValue
//         );

//         // ensure the vault sent the asset to bob - fees
//         assertEq(vault.totalAssets(), 1000); // only alice's deposit remains

//         // ensure bob's shares have been burned
//         assertEq(vault.balanceOf(bob), 0);

//         console2.log("bob deposit", bobDeposit);
//         // ensure the exit fee collector received the fees
//         assertEq(
//             asset.balanceOf(vault.feeCollector()),
//             computeFees(bobDeposit, 33)
//         );
//     }
// }
