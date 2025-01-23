// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
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
    ERC20 public immutable _asset;

    // withdrawal penalty corresponding to the maximal theoretical value of the assets outside the chain
    uint256 public constant WITHDRAWAL_PENALTY = 1_000; // 10%

    error InitialDepositTooLow(uint256 minimumDeposit);
    error RebaseExpired();
    error ZeroAddress();

    // ensure rebase did not expire
    modifier onlyValidRebase() {
        require(rebaseExpiresAt > block.number, RebaseExpired());
        _;
    }

    constructor(
        address initialOwner,
        ERC20 asset,
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
        _asset = asset;
    }

    /* ------------------SETTERS------------------ */

    /**
     * Override ERC4626.totalAssets to take into account the value outside the chain
     */
    function totalAssets() public view virtual override returns (uint256) {
        return localTotalAssets() + valueOutsideChain;
    }

    // returns the assets owned by the vault on this blockchain (only the assets in the supported protocols / contracts)
    // value returned is the corresponding ether value
    function localTotalAssets() public view virtual returns (uint256) {
        // todo: get values from all supported protocols
        return _asset.balanceOf(address(this));
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

        // redeem shares
        return redeem(shares, receiver, owner);
    }

    /* ------------------ALLOW WITHDRAWALS WITHOUT REBASE------------------ */
    /**
     * @notice Withdraw assets without requiring rebase
     * @dev This functions is not subject to rebase age validation but it is subject to a withdrawal penalty (unless last rebase value was 0) to avoid other users to losing value
     * This function is intended to be used unless Lobster cannot provide a rebase signature
     *
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address of the owner of the shares to burn
     */
    function withdrawWithoutRebase(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        shares = previewWithdraw(assets);
        _withdrawWithoutRebase(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @notice Redeem shares without requiring rebase
     * @dev This functions is not subject to rebase age validation but it is subject to a withdrawal penalty (unless last rebase value was 0) to avoid other users to losing value
     * This function is intended to be used unless Lobster cannot provide a rebase signature
     *
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address of the owner of the shares to burn
     */
    function redeemWithoutRebase(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        assets = previewRedeem(shares);
        _withdrawWithoutRebase(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @notice execute a withdraw without requiring a rebase but burns up to WITHDRAWAL_PENALTY/100 % of the shares to protect against value loss for the other users.
     * If the last rebase value was 0, there are no penalty
     */
    function _withdrawWithoutRebase(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        // penalty shares is 0 if the last rebase value was 0
        uint256 penaltyShares = 0;

        // else compute penalty shares
        if (valueOutsideChain > 0) {
            // compute penalty shares (ownerShares * WITHDRAWAL_PENALTY / 10000)
            penaltyShares = Math.mulDiv(shares, WITHDRAWAL_PENALTY, 10_000);

            // burn penalty shares
            _burn(owner, penaltyShares);
        }

        revert("Not implemented");
        // todo: if needed, call a validator function to retrieve funds from third party contracts
        super._withdraw(
            caller,
            receiver,
            owner,
            assets,
            shares - penaltyShares
        );
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
     * @dev Overrides ERC4626._withdraw to add rebase age validation
     * @inheritdoc ERC4626
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override onlyValidRebase {
        revert("Not implemented");
        // todo: if needed, call a validator function to retrieve funds from third party contracts
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ------------------UPDATE REBASE OPERATOR------------------ */

    function setRebaser(address newRebaser, bool enabled) external onlyOwner {
        require(newRebaser != address(0), ZeroAddress());
        rebaseOperators[newRebaser] = enabled;
    }
}
