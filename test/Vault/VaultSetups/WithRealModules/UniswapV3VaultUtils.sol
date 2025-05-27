// SPDX-License-Identifier: GNUv3
pragma solidity 0.8.28;

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

contract UniswapV3VaultUtils is UniswapV3Infra {
    using Math for uint256;

    UniV3LobsterVault public vault;
    UniswapV3Data public uniswapV3Data;

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

        // Capture initial state
        _DepositState memory state = _captureDepositState(depositor, packedAmounts);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(depositor, depositor, packedAmounts, state.expectedMintedShares);
        mintedShares = vault.deposit(packedAmounts, depositor);

        // Verify results
        _verifyDepositResults(depositor, state, mintedShares, amount0, amount1);

        vm.stopPrank();
        return mintedShares;
    }

    struct _DepositState {
        uint256 depositorInitialAsset0Balance;
        uint256 depositorInitialAsset1Balance;
        uint256 initialDepositorShares;
        uint256 vaultTotalSupplyBeforeDeposit;
        uint256 vaultInitialAsset0Balance;
        uint256 vaultInitialAsset1Balance;
        uint256 expectedMintedShares;
    }

    function _captureDepositState(
        address depositor,
        uint256 packedAmounts
    )
        private
        view
        returns (_DepositState memory state)
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
        address depositor,
        _DepositState memory state,
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
        vm.assertEq(vault.asset0().balanceOf(depositor), state.depositorInitialAsset0Balance - amount0);
        vm.assertEq(vault.asset1().balanceOf(depositor), state.depositorInitialAsset1Balance - amount1);
        vm.assertEq(vault.asset0().balanceOf(address(vault)), state.vaultInitialAsset0Balance + amount0);
        vm.assertEq(vault.asset1().balanceOf(address(vault)), state.vaultInitialAsset1Balance + amount1);

        vm.assertEq(vault.balanceOf(depositor), state.initialDepositorShares + mintedShares);

        vm.assertEq(vault.totalSupply(), state.vaultTotalSupplyBeforeDeposit + mintedShares);
    }

    // Function to mint vault shares and verify results
    function mintVaultShares(address user, uint256 sharesToMint) internal returns (uint256 assetsDeposited) {
        vm.startPrank(user);

        // Approve the vault to spend the assets
        vault.asset0().approve(address(vault), type(uint256).max);
        vault.asset1().approve(address(vault), type(uint256).max);

        _MintState memory state = _captureMintState(user, sharesToMint);

        // Ensure Mint event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, state.expectedDeposit, sharesToMint);
        assetsDeposited = vault.mint(sharesToMint, user);

        _verifyMintResults(user, state, assetsDeposited);

        vm.stopPrank();
        return assetsDeposited;
    }

    struct _MintState {
        uint256 userBalance0BeforeMint;
        uint256 userBalance1BeforeMint;
        uint256 expectedDeposit;
    }

    function _captureMintState(address user, uint256 sharesToMint) private view returns (_MintState memory state) {
        state.userBalance0BeforeMint = vault.asset0().balanceOf(user);
        state.userBalance1BeforeMint = vault.asset1().balanceOf(user);
        state.expectedDeposit = vault.previewMint(sharesToMint);
    }

    function _verifyMintResults(address user, _MintState memory state, uint256 assetsDeposited) private view {
        // Ensure the expected assets were deposited
        assertEq(state.expectedDeposit, assetsDeposited);

        // Ensure transfers happened
        (uint256 deposited0, uint256 deposited1) = decodePackedUint128(assetsDeposited);

        assertEq(state.userBalance0BeforeMint - deposited0, vault.asset0().balanceOf(user));
        assertEq(state.userBalance1BeforeMint - deposited1, vault.asset1().balanceOf(user));
    }

    // Struct to hold withdrawal state data
    struct WithdrawState {
        uint256 userBalance0Before;
        uint256 userBalance1Before;
        uint256 vaultTotalAssetsBefore;
        uint256 vaultTotalSupplyBefore;
        uint256 userSharesBefore;
        uint256 token0ToWithdraw;
        uint256 token1ToWithdraw;
    }

    // Struct to hold redeem state data
    struct RedeemState {
        uint256 userBalance0Before;
        uint256 userBalance1Before;
        uint256 expectedWithdraw0;
        uint256 expectedWithdraw1;
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

        WithdrawState memory state = _captureWithdrawState(user, packedAssetsToWithdraw);

        uint256 expectedShares = vault.previewWithdraw(packedAssetsToWithdraw);

        // Emit withdraw event
        emit IERC4626.Withdraw(user, user, user, packedAssetsToWithdraw, expectedShares);

        sharesRedeemed = vault.withdraw(packedAssetsToWithdraw, user, user);

        _verifyWithdrawResults(user, state, sharesRedeemed, expectedShares);

        vm.stopPrank();
        return sharesRedeemed;
    }

    // Helper function to capture initial state
    function _captureWithdrawState(
        address user,
        uint256 packedAssetsToWithdraw
    )
        private
        view
        returns (WithdrawState memory state)
    {
        state.userBalance0Before = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        state.userBalance1Before = IERC20(uniswapV3Data.tokenB).balanceOf(user);
        state.vaultTotalAssetsBefore = vault.totalAssets();
        state.vaultTotalSupplyBefore = vault.totalSupply();
        state.userSharesBefore = vault.balanceOf(user);

        (state.token0ToWithdraw, state.token1ToWithdraw) = decodePackedUint128(packedAssetsToWithdraw);
    }

    // Helper function to verify withdrawal results
    function _verifyWithdrawResults(
        address user,
        WithdrawState memory state,
        uint256 sharesRedeemed,
        uint256 expectedShares
    )
        private
        view
    {
        // Verify user token balances increased correctly
        assertEq(IERC20(uniswapV3Data.tokenA).balanceOf(user) - state.userBalance0Before, state.token0ToWithdraw);
        assertEq(IERC20(uniswapV3Data.tokenB).balanceOf(user) - state.userBalance1Before, state.token1ToWithdraw);

        // Verify vault total assets decreased correctly
        (uint256 total0Before, uint256 total1Before) = decodePackedUint128(state.vaultTotalAssetsBefore);
        (uint256 total0After, uint256 total1After) = decodePackedUint128(vault.totalAssets());

        assertEq(total0Before - total0After, state.token0ToWithdraw);
        assertEq(total1Before - total1After, state.token1ToWithdraw);

        // Verify shares were burned correctly
        assertEq(state.vaultTotalSupplyBefore - vault.totalSupply(), sharesRedeemed);
        assertEq(state.userSharesBefore - vault.balanceOf(user), sharesRedeemed);

        // Verify expected shares match actual shares redeemed
        assertEq(expectedShares, sharesRedeemed);
    }

    // Function to redeem vault shares and verify results
    function redeemVaultShares(address user, uint256 sharesToRedeem) internal returns (uint256 assetsWithdrawn) {
        vm.startPrank(user);

        RedeemState memory state = _captureRedeemState(user, sharesToRedeem);

        // Emit withdraw event
        emit IERC4626.Withdraw(user, user, user, vault.previewRedeem(sharesToRedeem), sharesToRedeem);

        assetsWithdrawn = vault.redeem(sharesToRedeem, user, user);

        _verifyRedeemResults(user, state);

        vm.stopPrank();
        return assetsWithdrawn;
    }

    // Helper function to capture initial redeem state
    function _captureRedeemState(
        address user,
        uint256 sharesToRedeem
    )
        private
        view
        returns (RedeemState memory state)
    {
        state.userBalance0Before = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        state.userBalance1Before = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        uint256 expectedWithdraw = vault.previewRedeem(sharesToRedeem);
        (state.expectedWithdraw0, state.expectedWithdraw1) = decodePackedUint128(expectedWithdraw);
    }

    // Helper function to verify redeem results
    function _verifyRedeemResults(address user, RedeemState memory state) private view {
        uint256 userBalance0After = IERC20(uniswapV3Data.tokenA).balanceOf(user);
        uint256 userBalance1After = IERC20(uniswapV3Data.tokenB).balanceOf(user);

        assertEq(userBalance0After, state.expectedWithdraw0 + state.userBalance0Before);
        assertEq(userBalance1After, state.expectedWithdraw1 + state.userBalance1Before);
    }

    function maxWithdraw(address user) internal returns (uint256 packedMaxWithdrawableAssets) {
        vm.startPrank(user);

        _MaxWithdrawState memory state = _captureMaxWithdrawState(user);

        // pack the assets
        uint256 packedExpectedAssets =
            packUint128(uint128(state.expectedTotalAssetsToWithdraw0), uint128(state.expectedTotalAssetsToWithdraw1));

        uint256 actualMaxWithdrawResult = vault.maxWithdraw(user);

        // Compute the expected and returned asset values
        vm.assertEq(packedExpectedAssets, actualMaxWithdrawResult);

        vm.stopPrank();
        return actualMaxWithdrawResult;
    }

    struct _MaxWithdrawState {
        uint256 totalSharesSupply;
        uint256 userShares;
        uint256 totalAssets0;
        uint256 totalAssets1;
        uint256 expectedTotalAssetsToWithdraw0;
        uint256 expectedTotalAssetsToWithdraw1;
    }

    function _captureMaxWithdrawState(address user) private view returns (_MaxWithdrawState memory state) {
        state.totalSharesSupply = vault.totalSupply();
        state.userShares = vault.balanceOf(user);

        (state.totalAssets0, state.totalAssets1,,) = getVaultTVL(vault);

        // Calculate the expected total assets to withdraw
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

        _MintPositionParams memory params =
            _prepareMintPositionParams(amount0Desired, amount1Desired, tickLower, tickUpper, slippagePercentageBp);

        BaseOp memory op = BaseOp({
            target: address(uniswapV3Data.positionManager),
            value: 0,
            data: abi.encodeCall(INonFungiblePositionManager.mint, params.mintParams)
        });

        vault.executeOp(Op(op, ""));
    }

    struct _MintPositionParams {
        INonFungiblePositionManager.MintParams mintParams;
    }

    function _prepareMintPositionParams(
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 tickLower,
        int24 tickUpper,
        uint256 slippagePercentageBp
    )
        private
        view
        returns (_MintPositionParams memory params)
    {
        address token0 = uniswapV3Data.tokenA < uniswapV3Data.tokenB ? uniswapV3Data.tokenA : uniswapV3Data.tokenB;
        address token1 = uniswapV3Data.tokenA < uniswapV3Data.tokenB ? uniswapV3Data.tokenB : uniswapV3Data.tokenA;

        uint256 amount0Min = (amount0Desired * (BASIS_POINT_SCALE - slippagePercentageBp)) / BASIS_POINT_SCALE;
        uint256 amount1Min = (amount1Desired * (BASIS_POINT_SCALE - slippagePercentageBp)) / BASIS_POINT_SCALE;

        params.mintParams = INonFungiblePositionManager.MintParams({
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
        });
    }

    struct Position {
        uint256 totalPositions0;
        uint256 totalPositions1;
        uint256 totalFees0;
        uint256 totalFees1;
    }

    // manually compute the vault tvl in order to compare it with the value returned by the vault
    function getVaultTVL(UniV3LobsterVault vault_)
        internal
        view
        returns (uint256 totalAssets0, uint256 totalAssets1, uint256 feeCut0, uint256 feeCut1)
    {
        uint256 vaultBalance0 = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault_));
        uint256 vaultBalance1 = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault_));

        Position memory positions = _calculatePositions(vault_);

        uint256 basisPointFeeCut = vault.feeCutBasisPoint();

        // Calculate the total assets in the vault
        totalAssets0 = vaultBalance0 + positions.totalPositions0
            + positions.totalFees0.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
        totalAssets1 = vaultBalance1 + positions.totalPositions1
            + positions.totalFees1.mulDiv(BASIS_POINT_SCALE - basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);

        feeCut0 = positions.totalFees0.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
        feeCut1 = positions.totalFees1.mulDiv(basisPointFeeCut, BASIS_POINT_SCALE, Math.Rounding.Floor);
    }

    function _calculatePositions(UniV3LobsterVault vault_) private view returns (Position memory positions) {
        uint256 uniswapPositionBalance = uniswapV3Data.positionManager.balanceOf(address(vault_));

        address wantedPoolAddress = _getWantedPoolAddress();

        for (uint256 i = 0; i < uniswapPositionBalance; i++) {
            uint256 tokenId = uniswapV3Data.positionManager.tokenOfOwnerByIndex(address(vault_), i);

            if (!_isValidPosition(tokenId, wantedPoolAddress)) {
                continue;
            }

            _addPositionValue(tokenId, wantedPoolAddress, positions);
        }
    }

    function _getWantedPoolAddress() private view returns (address) {
        PoolAddress.PoolKey memory wantedPoolKey =
            PoolAddress.getPoolKey(uniswapV3Data.tokenA, uniswapV3Data.tokenB, uniswapV3Data.poolFee);
        return PoolAddress.computeAddress(address(uniswapV3Data.factory), wantedPoolKey);
    }

    function _isValidPosition(uint256 tokenId, address wantedPoolAddress) private view returns (bool) {
        (,, address token0, address token1, uint24 fee,,,,,,,) = uniswapV3Data.positionManager.positions(tokenId);

        PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(token0, token1, fee);
        address computedPoolAddress = PoolAddress.computeAddress(address(uniswapV3Data.factory), key);

        return computedPoolAddress == wantedPoolAddress;
    }

    function _addPositionValue(uint256 tokenId, address poolAddress, Position memory positions) private view {
        // Get the current sqrt price from the pool
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(poolAddress).slot0();

        (uint256 amount0, uint256 fee0, uint256 amount1, uint256 fee1) =
            PositionValue.total(uniswapV3Data.positionManager, tokenId, sqrtPriceX96);

        positions.totalPositions0 += amount0;
        positions.totalPositions1 += amount1;
        positions.totalFees0 += fee0;
        positions.totalFees1 += fee1;
    }
}
