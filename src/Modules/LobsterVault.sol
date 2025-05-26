// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOpValidatorModule, BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE} from "./Constants.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Modular} from "../Modules/Modular.sol";

/**
 * @title LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault with 2 underlying tokens and operation validation mechanism
 */
contract LobsterVault is Modular {
    using Math for uint256;

    /**
     * @notice Thrown when a zero address is provided for a critical parameter
     */
    error ZeroAddress();

    /**
     * @dev The two tokens in the Uniswap V3 pool which are the vault's assets
     */
    IERC20 public immutable vaultAsset0;
    IERC20 public immutable vaultAsset1;

    /**
     * @notice Constructs a new LobsterVault
     */
    constructor(
        address initialOwner,
        IOpValidatorModule opValidator_,
        IERC20 vaultAsset0_,
        IERC20 vaultAsset1_
    ) ERC20("", "") ERC4626(IERC20(address(0))) {
        console.log("__________________");
        if (
            initialOwner == address(0) ||
            address(vaultAsset0_) == address(0) ||
            address(vaultAsset1_) == address(0)
        ) revert ZeroAddress();

        opValidator = opValidator_;
        emit OpValidatorSet(opValidator_);
    }

    /**
     * @dev See {IERC4626-deposit}.
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);

        (uint128 maxAssets0, uint128 maxAssets1) = unpackUint128(maxAssets);
        (uint128 assets0, uint128 assets1) = unpackUint128(assets);

        if (assets0 > maxAssets0 || assets1 > maxAssets1) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /**
     * @dev See {IERC4626-withdraw}.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);

        (uint128 maxAssets0, uint128 maxAssets1) = unpackUint128(maxAssets);
        (uint128 assets0, uint128 assets1) = unpackUint128(assets);

        if (assets0 > maxAssets0 || assets1 > maxAssets1) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /**
     * @dev Handles the deposit flow:
     * - Transfers 2 assets from caller to vault
     * - Mints shares to the receiver
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        (uint128 assets0, uint128 assets1) = unpackUint128(assets);

        // Execute the deposit
        if (assets0 > 0) {
            SafeERC20.safeTransferFrom(
                vaultAsset0,
                caller,
                address(this),
                assets0
            );
        }
        if (assets0 > 1) {
            SafeERC20.safeTransferFrom(
                vaultAsset1,
                caller,
                address(this),
                assets1
            );
        }

        _mint(receiver, shares);

        emit IERC4626.Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Handles the withdrawal flow:
     * - Extract the tokens from the Uniswap V3 positions
     * - Burns shares from the caller
     * - Transfers the assets to the receiver
     *
     * @dev Note: This function assumes the caller is the vault itself
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 /* assets */,
        uint256 shares
    ) internal override virtual {
        LobsterVault vault = LobsterVault(msg.sender);

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        // Avoid reentrancy with some ERCs by burning before transfer
        _burn(owner, shares);

        uint256 token0Balance = vaultAsset0.balanceOf(address(vault));
        uint256 token1Balance = vaultAsset1.balanceOf(address(vault));

        uint256 valueToWithdraw0 = token0Balance.mulDiv(shares, totalSupply());

        uint256 valueToWithdraw1 = token1Balance.mulDiv(shares, totalSupply());

        // Transfer the assets to the receiver
        if (valueToWithdraw0 > 0) {
            SafeERC20.safeTransfer(vaultAsset0, receiver, valueToWithdraw0);
        }
        if (valueToWithdraw1 > 0) {
            SafeERC20.safeTransfer(vaultAsset1, receiver, valueToWithdraw1);
        }

        uint256 withdrawnAssets = packUint128(
            uint128(valueToWithdraw0),
            uint128(valueToWithdraw1)
        );

        emit IERC4626.Withdraw(
            caller,
            receiver,
            owner,
            withdrawnAssets,
            shares
        );
    }

    /**
     * @dev Calculates the total value of assets in the calling vault
     * This includes:
     * - Direct token holdings
     * - Value locked in active Uniswap V3 positions
     * - Uncollected fees (minus the protocol fee cut)
     * @dev Note: This function assumes the caller is the vault itself
     *
     * @return totalValue The total value of assets in the vault packed as a single uint256 = (token0Value << 128) | token1Value
     */
    function totalAssets() public view override virtual returns (uint256 totalValue) {
        // Get the direct pool token balances owned by the vault
        uint256 amount0 = vaultAsset0.balanceOf(address(this));
        uint256 amount1 = vaultAsset1.balanceOf(address(this));

        // Pack the two uint128 values into a single uint256
        totalValue = packUint128(uint128(amount0), uint128(amount1));
    }

    /**
     * @dev See {IERC4626-convertToShares}. - returns theamount of shares using the limiting token
     */
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @dev See {IERC4626-convertToAssets}.
     */
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     * returns the amount of shares using the limiting token
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        // Todo: fix this fcking fct
        uint256 sharesSupply = LobsterVault(msg.sender).totalSupply();
        (uint256 totalAssets0, uint256 totalAssets1) = unpackUint128(
            totalAssets()
        );

        (uint256 asset0, uint256 asset1) = unpackUint128(assets);

        uint256 shares0 = asset0.mulDiv(
            sharesSupply + 10 ** _decimalsOffset(),
            totalAssets0 + 1,
            rounding
        );
        uint256 shares1 = asset1.mulDiv(
            sharesSupply + 10 ** _decimalsOffset(),
            totalAssets1 + 1,
            rounding
        );

        // return the minimal value
        return shares0 > shares1 ? shares0 : shares1;
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        uint256 sharesSupply = LobsterVault(msg.sender).totalSupply();
        (uint256 totalAssets0, uint256 totalAssets1) = unpackUint128(
            totalAssets()
        );

        uint256 asset0 = shares.mulDiv(
            totalAssets0 + 1,
            sharesSupply + 10 ** _decimalsOffset(),
            rounding
        );
        uint256 asset1 = shares.mulDiv(
            totalAssets1 + 1,
            sharesSupply + 10 ** _decimalsOffset(),
            rounding
        );

        return packUint128(uint128(asset0), uint128(asset1));
    }

    // Pack two uint128 values into a single uint256
    // (val1 << 128) | val2
    function packUint128(
        uint128 a,
        uint128 b
    ) internal pure returns (uint256 packed) {
        packed = (uint256(a) << 128) | uint256(b);
    }

    function unpackUint128(
        uint256 packed
    ) internal pure returns (uint128 a, uint128 b) {
        a = uint128(packed >> 128);
        b = uint128(packed);
    }
}
