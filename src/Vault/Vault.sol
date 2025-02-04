// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Op} from "../interfaces/IValidator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LobsterOpValidator as OpValidator} from "../Validator/OpValidator.sol";
import {LobsterPositionsManager as PositionsManager} from "../PositionsManager/PositionsManager.sol";

contract LobsterVault is Ownable2Step, ERC4626, OpValidator {
    using Math for uint256;

    PositionsManager public immutable positionManager;

    error InitialDepositTooLow(uint256 minimumDeposit);
    error NotEnoughAssets();
    error RebaseExpired();
    error ZeroAddress();

    // ensure rebase did not expire
    modifier onlyValidRebase() {
        require(rebaseExpiresAt > block.number, RebaseExpired());
        _;
    }

    constructor(
        address initialOwner,
        IERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        address lobsterAlgorithm_,
        address positionManager_,
        bytes memory validTargetsAndSelectorsData
    )
        Ownable(initialOwner)
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
        OpValidator(validTargetsAndSelectorsData)
    {
        if (
            initialOwner == address(0) ||
            lobsterAlgorithm_ == address(0) ||
            positionManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        lobsterAlgorithm = lobsterAlgorithm_;
        positionManager = PositionsManager(positionManager_);
    }

    /* ------------------SETTERS------------------ */

    /**
     * Override ERC4626.totalAssets to take into account the value outside the chain
     */
    function totalAssets() public view virtual override returns (uint256) {
        return localTotalAssets() + valueOutsideVault;
    }

    // returns the assets owned by the vault on this blockchain (only the assets in the supported protocols / contracts)
    // value returned is the corresponding ether value
    function localTotalAssets() public view virtual returns (uint256) {
        // todo: get values from all supported protocols
        return IERC20(asset()).balanceOf(address(this));
    }

    /* ------------------REBASE & IN/OUT------------------ */

    /**
     * @notice Verify the rebase signature and update the rebase value before depositing assets
     *
     * @param assets - the value of the assets to be deposited
     * @param receiver - the address that will receive the minted shares
     * @param rebaseData - the rebase data to be validated
     */
    function depositWithRebase(
        uint256 assets,
        address receiver,
        bytes calldata rebaseData
    ) external returns (uint256 shares) {
        // verify signature and update rebase value
        _verifyAndRebase(rebaseData);

        // deposit assets
        return deposit(assets, receiver);
    }

    /**
     * @notice Verify the rebase signature and update the rebase value before minting shares
     *
     * @param shares - the amount of shares to mint
     * @param receiver - the address that will receive the minted shares
     * @param rebaseData - the rebase data to be validated
     */
    function mintWithRebase(
        uint256 shares,
        address receiver,
        bytes calldata rebaseData
    ) external returns (uint256 assets) {
        // verify signature and update rebase value
        _verifyAndRebase(rebaseData);

        // mint shares
        return mint(shares, receiver);
    }

    /**
     * @notice Verify the rebase signature and update the rebase value before withdrawing assets
     *
     * @param assets - the amount of assets to withdraw
     * @param receiver - the address that will receive the withdrawn assets
     * @param owner - the address of the owner of the shares to burn
     * @param rebaseData - the rebase data to be validated
     */
    function withdrawWithRebase(
        uint256 assets,
        address receiver,
        address owner,
        bytes calldata rebaseData
    ) external returns (uint256 shares) {
        // verify signature and update rebase value
        _verifyAndRebase(rebaseData);

        // the minimal amount of assets accepted to be withdrawn by the caller
        uint256 minAmount = uint256(bytes32(rebaseData[1:33]));
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        /*
        determine how many assets will be withdrawn
        we use a minAmount because of a possible slippage happening when withdrawing and selling assets for eth from third-party contracts
        */
        if (vaultBalance < minAmount) {
            // vaultBalance < minAmount
            revert NotEnoughAssets();
        }

        if (vaultBalance < assets) {
            // minAmount <= vaultBalance < assets
            assets = vaultBalance;
        }
        // else minAmount <= assets <= vaultBalance and do nothing

        // withdraw assets
        return withdraw(assets, receiver, owner);
    }

    /**
     * @notice Verify the rebase signature and update the rebase value before redeeming shares
     *
     * @param shares - the amount of shares to redeem
     * @param receiver - the address that will receive the withdrawn assets
     * @param owner - the address of the owner of the shares to burn
     * @param rebaseData - the rebase data to be validated
     */
    function redeemWithRebase(
        uint256 shares,
        address receiver,
        address owner,
        bytes calldata rebaseData
    ) external returns (uint256 assets) {
        // verify signature and update rebase value
        _verifyAndRebase(rebaseData);

        // the minimal amount of assets accepted to be withdrawn by the caller
        uint256 minAmount = uint256(bytes32(rebaseData[1:33]));
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        // preview how many assets will be withdrawn at most
        assets = previewRedeem(shares);

        /*
        determine how many assets will be withdrawn
        we use a minAmount because of a possible slippage happening when withdrawing and selling assets for eth from third-party contracts
        */
        if (vaultBalance < minAmount) {
            // vaultBalance < minAmount
            revert NotEnoughAssets();
        }

        if (vaultBalance < assets) {
            // minAmount <= vaultBalance < assets
            assets = vaultBalance;
        }
        // else minAmount <= assets <= vaultBalance and do nothing

        // redeem shares
        return redeem(shares, receiver, owner);
    }

    /* ------------------OVERRIDE IN/OUT FUNCTIONS------------------ */
    /**
     * @dev Overrides ERC4626._deposit to add rebase age validation
     * @inheritdoc ERC4626
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override onlyValidRebase {
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Overrides ERC4626._withdraw to add rebase age validation.
     * @inheritdoc ERC4626
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override onlyValidRebase {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ------------------UPDATE REBASE OPERATOR------------------ */

    function setRebaser(address newRebaser, bool enabled) external onlyOwner {
        require(newRebaser != address(0), ZeroAddress());
        rebaseOperators[newRebaser] = enabled;
    }

    // /* ------------------RETRIEVE ASSETS FROM THIRD PARTY CONTRACTS------------------ */

    // /**
    //  * @notice Retrieve assets from uniswap only
    //  * @dev Verifies if the contract has enough assets to retrieve, if not, calls uniswap v3 supported pools to retrieve the assets
    //  * supported pools: uniV3 weth/wbtc
    //  * the assets that are not eth or weth are swapped on 1Inch
    //  *
    //  * @param amount - The amount of assets to retrieve
    //  * @return missingAssets - The amount of assets that could not be retrieved
    //  */
    // function retrieveAssets(
    //     uint256 amount
    // ) private returns (uint256 missingAssets) {
    //     // First check if the contract has enough assets to retrieve without calling third party contracts
    //     if (IERC20(asset()).balanceOf(address(this)) >= amount) {
    //         return 0;
    //     }

    //     // Else call third party contracts to retrieve the assets
    //     // Get tokens from Uniswap V3 weth/wbtc pool
    // }
}
