// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {UniV3LobsterVault, BASIS_POINT_SCALE} from "../../../../src/Vault/UniV3LobsterVault.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonFungiblePositionManager} from "../../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {UniswapV3Infra} from "../../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IUniswapV3RouterMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseOp, Op} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionValue} from "../../../../src/libraries/uniswapV3/PositionValue.sol";
import {PoolAddress} from "../../../../src/libraries/uniswapV3/PoolAddress.sol";
import {UniswapV3VaultUtils} from "./UniswapV3VaultUtils.sol";

struct DepositState {
    uint256 depositorInitialAsset0Balance;
    uint256 depositorInitialAsset1Balance;
    uint256 initialDepositorShares;
    uint256 vaultTotalSupplyBeforeDeposit;
    uint256 vaultInitialAsset0Balance;
    uint256 vaultInitialAsset1Balance;
    uint256 expectedMintedShares;
}

struct WithdrawTestState {
    uint256 userBalanceBeforeWithdraw0;
    uint256 userBalanceBeforeWithdraw1;
    uint256 vaultTotalAssetsBeforeWithdraw;
    uint256 vaultTotalSupplyBeforeWithdraw;
    uint256 userSharesBeforeWithdraw;
    uint256 token0ToWithdraw;
    uint256 token1ToWithdraw;
    uint256 expectedShares;
}

struct MaxWithdrawState {
    uint256 totalSharesSupply;
    uint256 userShares;
    uint256 totalAssets0;
    uint256 totalAssets1;
    uint256 expectedTotalAssetsToWithdraw0;
    uint256 expectedTotalAssetsToWithdraw1;
}

struct UniswapV3Data {
    IUniswapV3FactoryMinimal factory;
    INonFungiblePositionManager positionManager;
    IUniswapV3RouterMinimal router;
    address tokenA;
    address tokenB;
    uint24 poolFee;
    uint160 poolInitialSqrtPriceX96;
}

// Struct to hold position totals to avoid stack too deep error
struct PositionTotals {
    uint256 totalPositions0;
    uint256 totalPositions1;
    uint256 totalFees0;
    uint256 totalFees1;
}

contract UniV3LobsterVaultNoFeesSetup is UniswapV3VaultUtils {
    using Math for uint256;

    address public owner;
    address public alice;
    address public bob;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        address uniV3feeCutCollector = makeAddr("feeCollector");

        (IUniswapV3FactoryMinimal factory,, INonFungiblePositionManager positionManager, IUniswapV3RouterMinimal router)
        = deploy();

        uniswapV3Data.poolFee = 3000; // 0.3%
        uniswapV3Data.positionManager = positionManager;
        uniswapV3Data.factory = factory;
        uniswapV3Data.router = router;
        uniswapV3Data.poolInitialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 if both tokens have the same decimals value

        // Deploy and initialize the pool weth/mocked token pool
        IUniswapV3PoolMinimal pool = createPoolAndInitialize(
            uniswapV3Data.factory,
            address(new MockERC20()),
            address(new MockERC20()),
            uniswapV3Data.poolFee,
            uniswapV3Data.poolInitialSqrtPriceX96
        );

        uniswapV3Data.tokenA = pool.token0();
        uniswapV3Data.tokenB = pool.token1();

        // mint some tokens for the alice and bob
        MockERC20(uniswapV3Data.tokenA).mint(alice, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(alice, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenA).mint(bob, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(bob, 10000 ether); // 1000 tokens with 18 decimals

        // module instantiation
        IOpValidatorModule opValidator = new DummyValidator();

        vault = new UniV3LobsterVault(
            opValidator,
            pool,
            positionManager,
            uniV3feeCutCollector,
            0 // 0% fee cut,
        );
        // Setup initial state
        MockERC20(uniswapV3Data.tokenA).mint(alice, 10000 ether);
        MockERC20(uniswapV3Data.tokenB).mint(bob, 10000 ether);

        vm.startPrank(alice);
        MockERC20(uniswapV3Data.tokenA).approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(uniswapV3Data.tokenB).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // Helper function to calculate position values and avoid stack too deep
    function _calculatePositionValues(
        uint256 tokenId,
        address wantedPoolAddress
    )
        private
        view
        returns (uint256 amount0, uint256 fee0, uint256 amount1, uint256 fee1, bool isValidPool)
    {
        (,, address token0, address token1, uint24 fee,,,,,,,) = uniswapV3Data.positionManager.positions(tokenId);

        // Compute the pool address for this position
        PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(token0, token1, fee);
        address computedPoolAddress = PoolAddress.computeAddress(address(uniswapV3Data.factory), key);

        if (computedPoolAddress != wantedPoolAddress) {
            return (0, 0, 0, 0, false);
        }

        // Get the current sqrt price from the pool
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(computedPoolAddress).slot0();

        (amount0, fee0, amount1, fee1) = PositionValue.total(uniswapV3Data.positionManager, tokenId, sqrtPriceX96);

        return (amount0, fee0, amount1, fee1, true);
    }

    function _verifyDepositResults(
        DepositState memory state,
        uint256 mintedShares,
        uint256 amount0,
        uint256 amount1
    )
        private
        view
    {
        // Ensure the expected shares were minted
        vm.assertEq(state.expectedMintedShares, mintedShares);

        // ensure the transfers happened
        vm.assertEq(vault.asset0().balanceOf(alice), state.depositorInitialAsset0Balance - amount0);
        vm.assertEq(vault.asset1().balanceOf(alice), state.depositorInitialAsset1Balance - amount1);
        vm.assertEq(vault.asset0().balanceOf(address(vault)), state.vaultInitialAsset0Balance + amount0);
        vm.assertEq(vault.asset1().balanceOf(address(vault)), state.vaultInitialAsset1Balance + amount1);

        vm.assertEq(vault.balanceOf(alice), state.initialDepositorShares + mintedShares);
        vm.assertEq(vault.totalSupply(), state.vaultTotalSupplyBeforeDeposit + mintedShares);
    }

    function _verifyWithdrawResults(
        address user,
        WithdrawTestState memory state,
        uint256 sharesRedeemed
    )
        private
        view
    {
        uint256 userBalance0After = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalance1After = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        assertEq(userBalance0After - state.userBalanceBeforeWithdraw0, state.token0ToWithdraw);
        assertEq(userBalance1After - state.userBalanceBeforeWithdraw1, state.token1ToWithdraw);

        (uint256 total0Before, uint256 total1Before) = decodePackedUint128(state.vaultTotalAssetsBeforeWithdraw);
        (uint256 total0After, uint256 total1After) = decodePackedUint128(vault.totalAssets());

        assertEq(total0Before - total0After, state.token0ToWithdraw);
        assertEq(total1Before - total1After, state.token1ToWithdraw);
        assertEq(state.vaultTotalSupplyBeforeWithdraw - vault.totalSupply(), sharesRedeemed);
        assertEq(state.userSharesBeforeWithdraw - vault.balanceOf(user), sharesRedeemed);
        assertEq(state.expectedShares, sharesRedeemed);
    }
}
