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

contract UniV3LobsterVaultNoFeesSetup is UniswapV3Infra {
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

    /* ------------------------UTILS------------------------ */
    function packUint128(uint128 a, uint128 b) internal pure returns (uint256 packed) {
        packed = (uint256(a) << 128) | uint256(b);
    }

    function decodePackedUint128(uint256 packed) public pure returns (uint128 a, uint128 b) {
        a = uint128(packed >> 128);
        b = uint128(packed);
        return (a, b);
    }

    // Refactored deposit function
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

        // Capture state in struct
        DepositState memory state = _captureDepositState(depositor, packedAmounts);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(alice, alice, packedAmounts, state.expectedMintedShares);
        mintedShares = vault.deposit(packedAmounts, depositor);

        // Verify results
        _verifyDepositResults(state, mintedShares, amount0, amount1);

        vm.stopPrank();
        return mintedShares;
    }

    function _captureDepositState(
        address depositor,
        uint256 packedAmounts
    )
        private
        view
        returns (DepositState memory state)
    {
        state.depositorInitialAsset0Balance = vault.asset0().balanceOf(depositor);
        state.depositorInitialAsset1Balance = vault.asset1().balanceOf(depositor);
        state.initialDepositorShares = vault.balanceOf(depositor);
        state.vaultTotalSupplyBeforeDeposit = vault.totalSupply();
        state.vaultInitialAsset0Balance = vault.asset0().balanceOf(address(vault));
        state.vaultInitialAsset1Balance = vault.asset1().balanceOf(address(vault));
        state.expectedMintedShares = vault.previewDeposit(packedAmounts);
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

    // Refactored mint function
    function mintVaultShares(address user, uint256 sharesToMint) internal returns (uint256 assetsDeposited) {
        vm.startPrank(user);

        vault.asset0().approve(address(vault), type(uint256).max);
        vault.asset1().approve(address(vault), type(uint256).max);

        uint256 userBalance0BeforeMint = vault.asset0().balanceOf(user);
        uint256 userBalance1BeforeMint = vault.asset1().balanceOf(user);
        uint256 expectedDeposit = vault.previewMint(sharesToMint);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, expectedDeposit, sharesToMint);
        assetsDeposited = vault.mint(sharesToMint, user);

        assertEq(expectedDeposit, assetsDeposited);

        (uint256 deposited0, uint256 deposited1) = decodePackedUint128(assetsDeposited);
        assertEq(userBalance0BeforeMint - deposited0, vault.asset0().balanceOf(user));
        assertEq(userBalance1BeforeMint - deposited1, vault.asset1().balanceOf(user));

        vm.stopPrank();
        return assetsDeposited;
    }

    // Refactored redeem function
    function redeemVaultShares(address user, uint256 sharesToRedeem) internal returns (uint256 assetsWithdrawn) {
        vm.startPrank(user);

        uint256 userBalance0Before = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalance1Before = IERC20(uniswapV3Data.tokenB).balanceOf(user);
        uint256 expectedWithdraw = vault.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, user, expectedWithdraw, sharesToRedeem);

        assetsWithdrawn = vault.redeem(sharesToRedeem, user, user);

        (uint256 expectedWithdraw0, uint256 expectedWithdraw1) = decodePackedUint128(expectedWithdraw);

        uint256 userBalance0After = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalance1After = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        assertEq(userBalance0After, expectedWithdraw0 + userBalance0Before);
        assertEq(userBalance1After, expectedWithdraw1 + userBalance1Before);

        vm.stopPrank();
        return assetsWithdrawn;
    }

    // Refactored withdraw function
    function withdrawFromVault(
        address user,
        uint256 packedAssetsToWithdraw
    )
        internal
        returns (uint256 sharesRedeemed)
    {
        vm.startPrank(user);

        WithdrawTestState memory state = _captureWithdrawState(user, packedAssetsToWithdraw);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, user, packedAssetsToWithdraw, state.expectedShares);

        sharesRedeemed = vault.withdraw(packedAssetsToWithdraw, user, user);

        _verifyWithdrawResults(user, state, sharesRedeemed);

        vm.stopPrank();
        return sharesRedeemed;
    }

    function _captureWithdrawState(
        address user,
        uint256 packedAssetsToWithdraw
    )
        private
        view
        returns (WithdrawTestState memory state)
    {
        state.userBalanceBeforeWithdraw0 = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        state.userBalanceBeforeWithdraw1 = IERC20(uniswapV3Data.tokenB).balanceOf(user);
        state.vaultTotalAssetsBeforeWithdraw = vault.totalAssets();
        state.vaultTotalSupplyBeforeWithdraw = vault.totalSupply();
        state.userSharesBeforeWithdraw = vault.balanceOf(user);
        (state.token0ToWithdraw, state.token1ToWithdraw) = decodePackedUint128(packedAssetsToWithdraw);
        state.expectedShares = vault.previewWithdraw(packedAssetsToWithdraw);
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

    // Refactored maxWithdraw function
    function maxWithdraw(address user) internal returns (uint256 packedMaxWithdrawableAssets) {
        vm.startPrank(user);

        MaxWithdrawState memory state = _captureMaxWithdrawState(user);

        uint256 packedExpectedAssets =
            packUint128(uint128(state.expectedTotalAssetsToWithdraw0), uint128(state.expectedTotalAssetsToWithdraw1));

        uint256 actualMaxWithdrawResult = vault.maxWithdraw(user);
        vm.assertApproxEqAbs(packedExpectedAssets, actualMaxWithdrawResult, 2);

        vm.stopPrank();
        return actualMaxWithdrawResult;
    }

    function _captureMaxWithdrawState(address user) private view returns (MaxWithdrawState memory state) {
        state.totalSharesSupply = vault.totalSupply();
        state.userShares = vault.balanceOf(user);
        (state.totalAssets0, state.totalAssets1,,) = getVaultTVL(vault);

        state.expectedTotalAssetsToWithdraw0 =
            state.userShares.mulDiv(state.totalAssets0, state.totalSharesSupply, Math.Rounding.Floor);
        state.expectedTotalAssetsToWithdraw1 =
            state.userShares.mulDiv(state.totalAssets1, state.totalSharesSupply, Math.Rounding.Floor);
    }

    function maxRedeem(address user) public view returns (uint256) {
        uint256 expectedMaxRedeem = vault.balanceOf(user);
        vm.assertEq(expectedMaxRedeem, vault.maxRedeem(user));
        return expectedMaxRedeem;
    }

    // [Keep all your other functions the same - vaultOp functions, etc.]

    // Refactored getVaultTVL function
    function getVaultTVL(UniV3LobsterVault vault_)
        internal
        view
        returns (uint256 totalAssets0, uint256 totalAssets1, uint256 feeCut0, uint256 feeCut1)
    {
        uint256 vaultBalance0 = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault_));
        uint256 vaultBalance1 = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault_));

        PositionTotals memory totals = _calculateAllPositions(vault_);
        uint256 basisPointFeeCut = vault.feeCutBasisPoint();

        totalAssets0 = vaultBalance0 + totals.totalPositions0
            + totals.totalFees0.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);

        totalAssets1 = vaultBalance1 + totals.totalPositions1
            + totals.totalFees1.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);

        feeCut0 = totals.totalFees0.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
        feeCut1 = totals.totalFees1.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
    }

    function _calculateAllPositions(UniV3LobsterVault vault_) private view returns (PositionTotals memory totals) {
        uint256 uniswapPositionBalance = uniswapV3Data.positionManager.balanceOf(address(vault_));

        PoolAddress.PoolKey memory wantedPoolKey =
            PoolAddress.getPoolKey(uniswapV3Data.tokenA, uniswapV3Data.tokenB, uniswapV3Data.poolFee);
        address wantedPoolAddress = PoolAddress.computeAddress(address(uniswapV3Data.factory), wantedPoolKey);

        for (uint256 i = 0; i < uniswapPositionBalance; i++) {
            uint256 tokenId = uniswapV3Data.positionManager.tokenOfOwnerByIndex(address(vault_), i);

            (uint256 amount0, uint256 fee0, uint256 amount1, uint256 fee1, bool isValid) =
                _calculatePositionValues(tokenId, wantedPoolAddress);

            if (isValid) {
                totals.totalPositions0 += amount0;
                totals.totalPositions1 += amount1;
                totals.totalFees0 += fee0;
                totals.totalFees1 += fee1;
            }
        }
    }
}
