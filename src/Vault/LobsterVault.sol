// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE} from "../Modules/Constants.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Modular} from "../Modules/Modular.sol";
import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";

/**
 * @title LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault with dual-token asset support and operation validation mechanism
 */
contract LobsterVault is Modular {
    using Math for uint256;

    /**
     * @notice Thrown when a zero address is provided for a critical parameter
     */
    error ZeroAddress();

    /**
     * @dev The two tokens that compose the vault's dual-asset structure
     */
    IERC20 public immutable asset0;
    IERC20 public immutable asset1;

    event Assets(address indexed asset0, address indexed asset1);

    /**
     * @notice Constructs a new LobsterVault
     * @param opValidator_ The operation validator module for transaction validation
     * @param asset0_ The first token of the dual-asset pair
     * @param asset1_ The second token of the dual-asset pair
     */
    constructor(
        IOpValidatorModule opValidator_,
        IERC20 asset0_,
        IERC20 asset1_
    )
        ERC20("", "")
        ERC4626(IERC20(address(0)))
    {
        if (address(asset0_) == address(0) || address(asset1_) == address(0)) {
            revert ZeroAddress();
        }

        opValidator = opValidator_;

        asset0 = asset0_;
        asset1 = asset1_;
        emit Assets(address(asset0), address(asset1));
    }

    /**
     * @dev See {IERC4626-deposit}.
     * @param assets Packed uint256 containing both asset amounts: (asset0 << 128) | asset1
     * @param receiver Address to receive the minted shares
     * @return shares The amount of shares minted to the receiver
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
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
     * @param assets Packed uint256 containing both asset amounts: (asset0 << 128) | asset1
     * @param receiver Address to receive the withdrawn assets
     * @param owner Address that owns the shares being burned
     * @return shares The amount of shares burned from the owner
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
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
     * - Transfers both assets from caller to vault (if amounts > 0)
     * - Mints shares to the receiver
     * @param caller Address initiating the deposit
     * @param receiver Address to receive the minted shares
     * @param assets Packed uint256 containing both asset amounts
     * @param shares Amount of shares to mint
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        (uint128 assets0, uint128 assets1) = unpackUint128(assets);

        // Execute the deposit
        if (assets0 > 0) {
            SafeERC20.safeTransferFrom(asset0, caller, address(this), assets0);
        }
        if (assets1 > 0) {
            SafeERC20.safeTransferFrom(asset1, caller, address(this), assets1);
        }

        _mint(receiver, shares);

        emit IERC4626.Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Handles the withdrawal flow:
     * - Burns shares from the owner
     * - Calculates proportional amounts of both tokens based on current balances
     * - Transfers the calculated amounts to the receiver
     * @param caller Address initiating the withdrawal
     * @param receiver Address to receive the withdrawn assets
     * @param owner Address that owns the shares being burned
     * @param shares Amount of shares to burn
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256, /* assets */
        uint256 shares
    )
        internal
        virtual
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        // Avoid reentrancy with some ERCs by burning before transfer
        _burn(owner, shares);

        uint256 token0Balance = asset0.balanceOf(address(this));
        uint256 token1Balance = asset1.balanceOf(address(this));

        uint256 valueToWithdraw0 = token0Balance.mulDiv(shares, totalSupply());

        uint256 valueToWithdraw1 = token1Balance.mulDiv(shares, totalSupply());

        // Transfer the assets to the receiver
        if (valueToWithdraw0 > 0) {
            SafeERC20.safeTransfer(asset0, receiver, valueToWithdraw0);
        }
        if (valueToWithdraw1 > 0) {
            SafeERC20.safeTransfer(asset1, receiver, valueToWithdraw1);
        }

        uint256 withdrawnAssets = packUint128(uint128(valueToWithdraw0), uint128(valueToWithdraw1));

        emit IERC4626.Withdraw(caller, receiver, owner, withdrawnAssets, shares);
    }

    /**
     * @dev Calculates the total value of assets held directly by the vault
     * @return totalValue The total value of assets packed as uint256: (token0Balance << 128) | token1Balance
     */
    function totalAssets() public view virtual override returns (uint256 totalValue) {
        // Get the direct token balances owned by the vault
        uint256 amount0 = asset0.balanceOf(address(this));
        uint256 amount1 = asset1.balanceOf(address(this));

        // Pack the two uint128 values into a single uint256
        totalValue = packUint128(uint128(amount0), uint128(amount1));
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     * Uses the limiting token (whichever produces fewer shares) to determine the final share amount
     * @param assets Packed uint256 containing both asset amounts
     * @param rounding The rounding direction to use in calculations
     * @return shares The amount of shares calculated using the limiting token
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        (uint256 totalAssets0, uint256 totalAssets1) = unpackUint128(totalAssets());

        (uint256 assets0, uint256 assets1) = unpackUint128(assets);

        uint256 shares0 = assets0.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets0 + 1, rounding);
        uint256 shares1 = assets1.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets1 + 1, rounding);

        // return the minimal value
        return shares0 < shares1 ? shares0 : shares1;
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     * @param shares The amount of shares to convert
     * @param rounding The rounding direction to use in calculations
     * @return Packed uint256 containing both asset amounts: (asset0 << 128) | asset1
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 totalAssets0, uint256 totalAssets1) = unpackUint128(totalAssets());

        uint256 assets0 = shares.mulDiv(totalAssets0 + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
        uint256 assets1 = shares.mulDiv(totalAssets1 + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);

        return packUint128(uint128(assets0), uint128(assets1));
    }

    /**
     * @dev Pack two uint128 values into a single uint256
     * @param a First uint128 value (will be stored in upper 128 bits)
     * @param b Second uint128 value (will be stored in lower 128 bits)
     * @return packed The packed uint256 value: (a << 128) | b
     */
    function packUint128(uint128 a, uint128 b) internal pure returns (uint256 packed) {
        packed = (uint256(a) << 128) | uint256(b);
    }

    /**
     * @dev Unpack a uint256 into two uint128 values
     * @param packed The packed uint256 value
     * @return a The upper 128 bits as uint128
     * @return b The lower 128 bits as uint128
     */
    function unpackUint128(uint256 packed) internal pure returns (uint128 a, uint128 b) {
        a = uint128(packed >> 128);
        b = uint128(packed);
    }
}
