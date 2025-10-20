// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault, Position} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultLockTest is Test {
    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();

        // Setup with funds and initial position
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
    }

    function test_mint_locked() public {
        vm.startPrank(setup.vault.owner());
        setup.vault.lock(true);
        vm.stopPrank();

        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;
        uint256 amount0Desired = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1Desired = TestConstants.MEDIUM_AMOUNT;

        vm.expectRevert(SingleVault.ContractLocked.selector);
        helper.createPosition(setup.vault, setup.allocator, tickLower, tickUpper, amount0Desired, amount1Desired);
    }

    function test_burn_locked() public {
        vm.startPrank(setup.vault.owner());
        setup.vault.lock(true);
        vm.stopPrank();

        vm.prank(setup.allocator);
        vm.expectRevert(SingleVault.ContractLocked.selector);
        setup.vault.burn(-1, 1, 10); // random values since we should not even enter the function
    }

    function test_collect_locked() public {
        vm.startPrank(setup.vault.owner());
        setup.vault.lock(true);
        vm.stopPrank();

        vm.prank(setup.allocator);
        vm.expectRevert(SingleVault.ContractLocked.selector);
        setup.vault.collect(-1, 1, 10, 10); // random values since we should not even enter the function
    }
}
