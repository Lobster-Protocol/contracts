// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees} from "../../src/Vault/ERC4626Fees.sol";
import {BASIS_POINT_SCALE} from "../../src/Vault/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// test deposit / withdraw / mint / redeem preview functions
contract VaultPreviewFunctions is VaultTestSetup {
    using Math for uint256;

    // the default fess are set to 0

    /* -----------------------TEST PREVIEW NO FEES----------------------- */
    function testPreviewDepositNoFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        // deposit 1000
        uint256 depositAmount = 1000;
        uint256 shares = vault.previewDeposit(depositAmount);

        // at first, 1 share = 1 asset
        assertEq(shares, depositAmount);
    }

    function testPreviewMintNoFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        // deposit 1000
        uint256 mintAmount = 1000;
        uint256 assets = vault.previewMint(mintAmount);

        // at first, 1 share = 1 asset
        assertEq(assets, mintAmount);
    }

    function testPreviewWithdrawNoFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        // deposit 1000
        uint256 assetsToWithdraw = 1000;
        uint256 shares = vault.previewWithdraw(assetsToWithdraw);

        // at first, 1 share = 1 asset
        assertEq(shares, assetsToWithdraw);
    }

    function testPreviewRedeemNoFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        // deposit 1000
        uint256 sharesToRedeem = 1000;
        uint256 assets = vault.previewRedeem(sharesToRedeem);

        // at first, 1 share = 1 asset
        assertEq(assets, sharesToRedeem);
    }

    /* -----------------------PREVIEW FUNCTIONS WITH FEES----------------------- */
    function testPreviewDepositFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 entryFeeBasisPoints = 100; // 1%
        setEntryFeeBasisPoint(entryFeeBasisPoints);

        // deposit 1000
        uint256 depositAmount = 1000;
        uint256 expectedFee = computeFees(depositAmount, entryFeeBasisPoints);
        uint256 shares = vault.previewDeposit(depositAmount);

        // at first, 1 share = 1 asset, shares = depositAmount - fee
        assertEq(shares, depositAmount - expectedFee);
    }

    function testPreviewMintFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 entryFeeBasisPoints = 100; // 1%
        setEntryFeeBasisPoint(entryFeeBasisPoints);

        // deposit 1000
        uint256 mintAmount = 1000;
        uint256 expectedFee = computeFees(mintAmount, entryFeeBasisPoints);
        uint256 assets = vault.previewMint(mintAmount);

        // at first, 1 share = 1 asset, assets = mintAmount + expectedFee (we send the amount of shares to get how many assets we must send to get (+ fees))
        assertEq(assets, mintAmount + expectedFee);
    }

    function testPreviewWithdrawFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 exitFeeBasisPoints = 100; // 1%
        setExitFeeBasisPoint(exitFeeBasisPoints);

        // deposit 1000
        uint256 assetsToWithdraw = 1000;
        uint256 expectedFee = computeFees(assetsToWithdraw, exitFeeBasisPoints);
        uint256 shares = vault.previewWithdraw(assetsToWithdraw);

        // at first, 1 share = 1 asset
        assertEq(shares, assetsToWithdraw + expectedFee);
    }

    function testPreviewRedeemFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 exitFeeBasisPoints = 100; // 1%
        setExitFeeBasisPoint(exitFeeBasisPoints);

        // deposit 1000
        uint256 sharesToRedeem = 1000;
        uint256 expectedFee = computeFees(sharesToRedeem, exitFeeBasisPoints);
        uint256 assets = vault.previewRedeem(sharesToRedeem);

        // at first, 1 share = 1 asset
        assertEq(assets, sharesToRedeem - expectedFee);
    }
}
