// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

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

struct UniswapV3Data {
    IUniswapV3FactoryMinimal factory;
    INonFungiblePositionManager positionManager;
    IUniswapV3RouterMinimal router;
    address tokenA;
    address tokenB;
    uint24 poolFee;
    uint160 poolInitialSqrtPriceX96;
}

contract UniV3LobsterVaultTest is UniswapV3Infra {
    using Math for uint256;

    address public owner;
    address public alice;
    address public bob;
    UniV3LobsterVault public vault;

    UniswapV3Data public uniswapV3Data;

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
            owner,
            opValidator,
            pool,
            positionManager,
            uniV3feeCutCollector,
            0, // 0% fee cut,
            IERC20(uniswapV3Data.tokenA),
            IERC20(uniswapV3Data.tokenB)
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

    /* ------------------------UTILS------------------------ */
    function packUint128(uint128 a, uint128 b) internal pure returns (uint256 packed) {
        packed = (uint256(a) << 128) | uint256(b);
    }

    function decodePackedUint128(uint256 packed) public pure returns (uint128 a, uint128 b) {
        // Extract the first uint128 (higher order bits)
        a = uint128(packed >> 128);

        // Extract the second uint128 (lower order bits)
        b = uint128(packed);

        return (a, b);
    }

    // Function to perform vault deposit and verify results
    function depositToVault(
        address depositor,
        uint256 amount0,
        uint256 amount1
    )
        internal
        returns (uint256 mintedShares)
    {
        uint256 packedAmounts = packUint128(uint128(amount0), uint128(amount1));

        vm.startPrank(depositor);

        // Approve the vault to spend the assets
        vault.asset0().approve(address(vault), type(uint256).max);
        vault.asset1().approve(address(vault), type(uint256).max);

        uint256 depositorInitialAsset0Balance = vault.asset0().balanceOf(depositor);
        uint256 depositorInitialAsset1Balance = vault.asset1().balanceOf(depositor);
        uint256 initialDepositorShares = vault.balanceOf(depositor);

        uint256 vaultTotalSupplyBeforeDeposit = vault.totalSupply();
        uint256 vaultInitialAsset0Balance = vault.asset0().balanceOf(address(vault));
        uint256 vaultInitialAsset1Balance = vault.asset1().balanceOf(address(vault));

        uint256 expectedMintedShares = vault.previewDeposit(packedAmounts);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(alice, alice, packedAmounts, expectedMintedShares);
        mintedShares = vault.deposit(packedAmounts, depositor);

        // Ensure the expected shares were minted
        vm.assertEq(expectedMintedShares, mintedShares);

        // ensure the transfers happened
        vm.assertEq(vault.asset0().balanceOf(alice), depositorInitialAsset0Balance - amount0);
        vm.assertEq(vault.asset1().balanceOf(alice), depositorInitialAsset1Balance - amount1);
        vm.assertEq(vault.asset0().balanceOf(address(vault)), vaultInitialAsset0Balance + amount0);
        vm.assertEq(vault.asset1().balanceOf(address(vault)), vaultInitialAsset1Balance + amount1);

        vm.assertEq(vault.balanceOf(alice), initialDepositorShares + mintedShares);

        vm.assertEq(vault.totalSupply(), vaultTotalSupplyBeforeDeposit + mintedShares);

        vm.stopPrank();
        return mintedShares;
    }

    // Function to mint vault shares and verify results
    function mintVaultShares(address user, uint256 sharesToMint) internal returns (uint256 assetsDeposited) {
        vm.startPrank(user);

        // Approve the vault to spend the assets
        vault.asset0().approve(address(vault), type(uint256).max);
        vault.asset1().approve(address(vault), type(uint256).max);

        uint256 userBalance0BeforeMint = vault.asset0().balanceOf(user);
        uint256 userBalance1BeforeMint = vault.asset1().balanceOf(user);

        uint256 expectedDeposit = vault.previewMint(sharesToMint);

        // Ensure Mint event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, expectedDeposit, sharesToMint);
        assetsDeposited = vault.mint(sharesToMint, user);

        // Ensure the expected assets were deposited
        assertEq(expectedDeposit, assetsDeposited);

        // Ensure transfers happened
        (uint256 deposited0, uint256 deposited1) = decodePackedUint128(assetsDeposited);

        assertEq(userBalance0BeforeMint - deposited0, vault.asset0().balanceOf(user));
        assertEq(userBalance1BeforeMint - deposited1, vault.asset1().balanceOf(user));

        vm.stopPrank();
        return assetsDeposited;
    }

    // Function to redeem vault shares and verify results
    function redeemVaultShares(address user, uint256 sharesToRedeem) internal returns (uint256 assetsWithdrawn) {
        vm.startPrank(user);

        uint256 aliceBalanceBeforeWithdraw0 = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 aliceBalanceBeforeWithdraw1 = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        uint256 expectedWithdraw = vault.previewRedeem(sharesToRedeem);

        // ensure the withdraw event is emitted
        // vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, user, expectedWithdraw, sharesToRedeem);

        assetsWithdrawn = vault.redeem(sharesToRedeem, user, user);

        // Verify asset balances
        uint256 aliceBalanceAfterWithdraw0 = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 aliceBalanceAfterWithdraw1 = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        (uint256 expectedWithdraw0, uint256 expectedWithdraw1) = decodePackedUint128(expectedWithdraw);
        assertEq(aliceBalanceAfterWithdraw0, expectedWithdraw0 + aliceBalanceBeforeWithdraw0);
        assertEq(aliceBalanceAfterWithdraw1, expectedWithdraw1 + aliceBalanceBeforeWithdraw1);

        vm.stopPrank();
        return assetsWithdrawn;
    }

    // Function to withdraw assets from vault and verify results
    function withdrawFromVault(
        address user,
        uint256 packedAssetsToWithdraw
    )
        internal
        returns (uint256 sharesRedeemed)
    {
        vm.startPrank(user);

        uint256 userBalanceBeforeWithdraw0 = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalanceBeforeWithdraw1 = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        uint256 vaultTotalAssetsBeforeWithdraw = vault.totalAssets();

        uint256 vaultTotalSupplyBeforeWithdraw = vault.totalSupply();
        uint256 userSharesBeforeWithdraw = vault.balanceOf(user);

        (uint256 token0ToWithdraw, uint256 token1ToWithdraw) = decodePackedUint128(packedAssetsToWithdraw);

        uint256 expectedShares = vault.previewWithdraw(packedAssetsToWithdraw);

        // ensure the withdraw event is emitted
        // vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, user, packedAssetsToWithdraw, expectedShares);

        sharesRedeemed = vault.withdraw(packedAssetsToWithdraw, user, user);

        // Verify asset balances
        uint256 userBalanceAfterWithdraw0 = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalanceAfterWithdraw1 = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        uint256 vaultTotalAssetsAfterWithdraw = vault.totalAssets();

        uint256 vaultTotalSupplyAfterWithdraw = vault.totalSupply();
        uint256 userSharesAfterWithdraw = vault.balanceOf(user);

        assertEq(userBalanceAfterWithdraw0 - userBalanceBeforeWithdraw0, token0ToWithdraw);
        assertEq(userBalanceAfterWithdraw1 - userBalanceBeforeWithdraw1, token1ToWithdraw);
        (uint256 total0Before, uint256 total1Before) = decodePackedUint128(vaultTotalAssetsBeforeWithdraw);
        (uint256 total0After, uint256 total1After) = decodePackedUint128(vaultTotalAssetsAfterWithdraw);
        assertEq(total0Before - total0After, token0ToWithdraw);
        assertEq(total1Before - total1After, token1ToWithdraw);
        assertEq(vaultTotalSupplyBeforeWithdraw - vaultTotalSupplyAfterWithdraw, sharesRedeemed);
        assertEq(userSharesBeforeWithdraw - userSharesAfterWithdraw, sharesRedeemed);

        // Ensure the expected shares were redeemed
        assertEq(expectedShares, sharesRedeemed);

        vm.stopPrank();
        return sharesRedeemed;
    }

    function maxWithdraw(address user) internal returns (uint256 packedMaxWithdrawableAssets) {
        vm.startPrank(user);

        uint256 totalSharesSupply = vault.totalSupply();
        uint256 userShares = vault.balanceOf(user);

        (uint256 totalAssets0, uint256 totalAssets1,,) = getVaultTVL(vault);

        // Calculate the expected total assets to withdraw
        uint256 expectedTotalAssetsToWithdraw0 = userShares.mulDiv(totalAssets0, totalSharesSupply, Math.Rounding.Floor);
        uint256 expectedTotalAssetsToWithdraw1 = userShares.mulDiv(totalAssets1, totalSharesSupply, Math.Rounding.Floor);

        // pack the assets
        uint256 packedExpectedAssets =
            packUint128(uint128(expectedTotalAssetsToWithdraw0), uint128(expectedTotalAssetsToWithdraw1));

        uint256 actualMaxWithdrawResult = vault.maxWithdraw(user);

        // Compute the expected and returned asset values
        vm.assertEq(packedExpectedAssets, actualMaxWithdrawResult);

        vm.stopPrank();
        return actualMaxWithdrawResult;
    }

    function maxRedeem(address user) public view returns (uint256) {
        uint256 expectedMaxRedeem = vault.balanceOf(user);

        vm.assertEq(expectedMaxRedeem, vault.maxRedeem(user));

        return expectedMaxRedeem;
    }

    // Function to approve token spending
    function vaultOpApproveToken(address token, address spender) internal {
        BaseOp memory op = BaseOp({
            target: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (spender, type(uint256).max))
        });
        vault.executeOp(Op(op, ""));
    }

    function vaultOpSwapTokens(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 slippageBasisPoint
    )
        internal
        returns (uint256 amountOut)
    {
        uint256 amountOutMinimum = amountIn.mulDiv(BASIS_POINT_SCALE - slippageBasisPoint, BASIS_POINT_SCALE);

        BaseOp memory op = BaseOp({
            target: address(uniswapV3Data.router),
            value: 0,
            data: abi.encodeCall(
                IUniswapV3RouterMinimal.exactInputSingle,
                (
                    IUniswapV3RouterMinimal.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: fee,
                        recipient: address(vault),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: 0
                    })
                )
            )
        });

        vault.executeOp(Op(op, ""));

        return IERC20(tokenOut).balanceOf(address(vault));
    }

    function vaultOpMintUniswapPosition(
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 tickLower,
        int24 tickUpper,
        uint256 slippagePercentageBp
    )
        internal
    {
        vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));
        vaultOpApproveToken(uniswapV3Data.tokenB, address(uniswapV3Data.positionManager));

        address token0 = uniswapV3Data.tokenA < uniswapV3Data.tokenB ? uniswapV3Data.tokenA : uniswapV3Data.tokenB;
        address token1 = uniswapV3Data.tokenA < uniswapV3Data.tokenB ? uniswapV3Data.tokenB : uniswapV3Data.tokenA;

        uint256 amount0Min = (amount0Desired * (BASIS_POINT_SCALE - slippagePercentageBp)) / BASIS_POINT_SCALE;
        uint256 amount1Min = (amount1Desired * (BASIS_POINT_SCALE - slippagePercentageBp)) / BASIS_POINT_SCALE;

        BaseOp memory op = BaseOp({
            target: address(uniswapV3Data.positionManager),
            value: 0,
            data: abi.encodeCall(
                INonFungiblePositionManager.mint,
                (
                    INonFungiblePositionManager.MintParams({
                        token0: token0,
                        token1: token1,
                        fee: uniswapV3Data.poolFee,
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        amount0Desired: amount0Desired,
                        amount1Desired: amount1Desired,
                        amount0Min: amount0Min,
                        amount1Min: amount1Min,
                        recipient: address(vault),
                        deadline: block.timestamp
                    })
                )
            )
        });

        vault.executeOp(Op(op, ""));
    }

    // manually compute the vault tvl in order to compare it with the value returned by the vault
    function getVaultTVL(UniV3LobsterVault vault_)
        internal
        view
        returns (uint256 totalAssets0, uint256 totalAssets1, uint256 feeCut0, uint256 feeCut1)
    {
        // Manually calculate the expected max assets to withdraw
        // Take into account: vault balance for both tokens, uniswap position
        // (only) in the supported pool (active positions and unclaimed fees)

        uint256 vaultBalance0 = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault_));
        uint256 vaultBalance1 = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault_));

        uint256 uniswapPositionBalance = uniswapV3Data.positionManager.balanceOf(address(vault_));

        uint256 totalPositions0 = 0;
        uint256 totalPositions1 = 0;
        uint256 totalFees0 = 0;
        uint256 totalFees1 = 0;

        for (uint256 i = 0; i < uniswapPositionBalance; i++) {
            uint256 tokenId = uniswapV3Data.positionManager.tokenOfOwnerByIndex(address(vault_), i);
            (,, address token0, address token1, uint24 fee,,,,,,,) = uniswapV3Data.positionManager.positions(tokenId);
            // Compute the pool address for this position
            PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(token0, token1, fee);
            address computedPoolAddress = PoolAddress.computeAddress(address(uniswapV3Data.factory), key);

            PoolAddress.PoolKey memory wantedPoolKey =
                PoolAddress.getPoolKey(uniswapV3Data.tokenA, uniswapV3Data.tokenB, uniswapV3Data.poolFee);
            address wantedPoolAddress = PoolAddress.computeAddress(address(uniswapV3Data.factory), wantedPoolKey);

            if (computedPoolAddress != wantedPoolAddress) {
                continue;
            }

            // Get the current sqrt price from the pool
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(computedPoolAddress).slot0();

            (uint256 amount0, uint256 fee0, uint256 amount1, uint256 fee1) =
                PositionValue.total(uniswapV3Data.positionManager, tokenId, sqrtPriceX96);

            totalPositions0 += amount0;
            totalPositions1 += amount1;
            totalFees0 += fee0;
            totalFees1 += fee1;
        }

        uint256 basisPointFeeCut = vault.feeCutBasisPoint();

        // Calculate the total assets in the vault
        totalAssets0 = vaultBalance0 + totalPositions0
            + totalFees0.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);

        totalAssets1 = vaultBalance1 + totalPositions1
            + totalFees1.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);

        feeCut0 = totalFees0.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
        feeCut1 = totalFees1.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
    }
}
