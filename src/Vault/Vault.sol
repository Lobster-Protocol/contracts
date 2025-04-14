// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC4626Fees} from "./ERC4626Fees.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LobsterPositionsManager as PositionsManager} from "../PositionsManager/PositionsManager.sol";
import {BASIS_POINT_SCALE} from "./Constants.sol";
import {Modular} from "../Modules/Modular.sol";

contract LobsterVault is Modular, ERC4626Fees {
    using Math for uint256;

    PositionsManager public immutable positionManager;
    event FeesCollected(
        uint256 total,
        uint256 managementFees,
        uint256 performanceFees,
        uint256 timestamp
    );

    error InitialDepositTooLow(uint256 minimumDeposit);
    error NotEnoughAssets();
    // error RebaseExpired();
    error ZeroAddress();

    // // ensure rebase did not expire
    // modifier onlyValidRebase() {
    //     require(rebaseExpiresAt > block.number, RebaseExpired());
    //     _;
    // }

    // todo: add initial fees
    constructor(
        address initialOwner,
        IERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        address lobsterAlgorithm_,
        address positionManager_,
        // bytes memory validTargetsAndSelectorsData,
        address initialFeeCollector
    )
        Ownable(initialOwner)
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
        ERC4626Fees(initialFeeCollector)
    {
        if (
            initialOwner == address(0) ||
            lobsterAlgorithm_ == address(0) ||
            positionManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        // lobsterAlgorithm = lobsterAlgorithm_;
        positionManager = PositionsManager(positionManager_);
    }

    /* ------------------SETTERS------------------ */

    /**
     * Override ERC4626.totalAssets to take into account the value outside the chain
     */
    function totalAssets() public view virtual override returns (uint256) {
        // todo: use module for this
        // return localTotalAssets() + valueOutsideVault;
    }

    // returns the assets owned by the vault on this blockchain (only the assets in the supported protocols / contracts)
    // value returned is the corresponding ether value
    function localTotalAssets() public view virtual returns (uint256) {
        // todo: use module for this
        // todo: get values from all supported protocols
        return IERC20(asset()).balanceOf(address(this));
    }

    /* ------------------REBASE & IN/OUT------------------ */

    // /**
    //  * @notice Verify the rebase signature and update the rebase value before depositing assets
    //  *
    //  * @param assets - the value of the assets to be deposited
    //  * @param receiver - the address that will receive the minted shares
    //  * @param rebaseData - the rebase data to be validated
    //  */
    // function depositWithRebase(
    //     uint256 assets,
    //     address receiver,
    //     bytes calldata rebaseData
    // ) external returns (uint256 shares) {
    //     // verify signature and update rebase value
    //     _verifyAndRebase(rebaseData);

    //     // deposit assets
    //     return deposit(assets, receiver);
    // }

    // /**
    //  * @notice Verify the rebase signature and update the rebase value before minting shares
    //  *
    //  * @param shares - the amount of shares to mint
    //  * @param receiver - the address that will receive the minted shares
    //  * @param rebaseData - the rebase data to be validated
    //  */
    // function mintWithRebase(
    //     uint256 shares,
    //     address receiver,
    //     bytes calldata rebaseData
    // ) external returns (uint256 assets) {
    //     // verify signature and update rebase value
    //     _verifyAndRebase(rebaseData);

    //     // mint shares
    //     return mint(shares, receiver);
    // }

    // /**
    //  * @notice Verify the rebase signature and update the rebase value before withdrawing assets
    //  *
    //  * @param assets - the amount of assets to withdraw
    //  * @param receiver - the address that will receive the withdrawn assets
    //  * @param owner - the address of the owner of the shares to burn
    //  * @param rebaseData - the rebase data to be validated
    //  */
    // function withdrawWithRebase(
    //     uint256 assets,
    //     address receiver,
    //     address owner,
    //     bytes calldata rebaseData
    // ) external returns (uint256 shares) {
    //     // verify signature and update rebase value
    //     _verifyAndRebase(rebaseData);

    //     // the minimal amount of assets accepted to be withdrawn by the caller
    //     uint256 minAmount = uint256(bytes32(rebaseData[1:33]));
    //     uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

    //     // shares owned by the owner before withdrawing. All those shares will be burnt
    //     uint256 initialShares = previewWithdraw(assets);

    //     /*
    //     determine how many assets will be withdrawn
    //     we use a minAmount because of a possible slippage happening when withdrawing and selling tokens for assets in third-party contracts
    //     */
    //     if (vaultBalance < minAmount) {
    //         // vaultBalance < minAmount
    //         revert NotEnoughAssets();
    //     }

    //     if (vaultBalance < assets) {
    //         // minAmount <= vaultBalance < assets
    //         assets = vaultBalance;
    //     }
    //     // else minAmount <= assets <= vaultBalance and do nothing

    //     // withdraw assets
    //     shares = withdraw(assets, receiver, owner);

    //     // Ensure all the shares were burnt and there are no leftovers
    //     /*
    //     When withdrawing, the withdrawOperations from _verifyAndRebase can swap some tokens back to the asset. By doing so, there might be a slippage.
    //     By calling withdraw, the shares are burnt depending on the asset balance that can be affected by the slippage.
    //     For instance, if the withdrawer wants to withdraw 10 assets and during withdrawOperations, we exit a UniV3 position (let's say WBTC/asset) and swap
    //     the WBTC back to asset, we would get 5 assets and x WBTC converted to 4.9 assets. The withdrawer would get 9.9 assets instead of 10 assets. when
    //     calling withdraw, we can only burn shares equivalent to 9.9 assets but the withdrawer would still have shares equivalent to 0.1 assets left in the
    //     contract. This would dilute everyone else's shares. To avoid this, we burn the leftOvers shares here.
    //     */
    //     uint256 leftOvers = initialShares - shares;
    //     if (leftOvers > 0) {
    //         _burn(owner, leftOvers);
    //     }

    //     return shares;
    // }

    // /**
    //  * @notice Verify the rebase signature and update the rebase value before redeeming shares
    //  *
    //  * @param shares - the amount of shares to redeem
    //  * @param receiver - the address that will receive the withdrawn assets
    //  * @param owner - the address of the owner of the shares to burn
    //  * @param rebaseData - the rebase data to be validated
    //  */
    // function redeemWithRebase(
    //     uint256 shares,
    //     address receiver,
    //     address owner,
    //     bytes calldata rebaseData // todo: move the minAmount somewhere else
    // ) external returns (uint256 assets) {
    //     // verify signature and update rebase value
    //     _verifyAndRebase(rebaseData);

    //     // the minimal amount of assets accepted to be withdrawn by the caller
    //     uint256 minAmount = uint256(bytes32(rebaseData[1:33]));
    //     uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
    //     // the initial shares the user want to redeem
    //     uint256 initialShares = shares;

    //     // preview how many assets will be withdrawn at most
    //     assets = previewRedeem(shares);

    //     /*
    //     determine how many assets will be withdrawn
    //     we use a minAmount because of a possible slippage happening when withdrawing and selling assets for eth from third-party contracts
    //     */
    //     if (vaultBalance < minAmount) {
    //         // vaultBalance < minAmount
    //         revert NotEnoughAssets();
    //     }

    //     if (vaultBalance < assets) {
    //         // minAmount <= vaultBalance < assets
    //         assets = vaultBalance;
    //         shares = convertToShares(assets);
    //     }
    //     // else minAmount <= assets <= vaultBalance and do nothing

    //     // the shares that will be used to redeem (will withdraw some assets between minAmount and assets)
    //     uint256 initialOwnerShares = balanceOf(owner);

    //     // redeem shares
    //     assets = redeem(shares, receiver, owner);

    //     // Ensure all the shares were burnt and there are no leftovers
    //     /*
    //     When redeeming, the withdrawOperations from _verifyAndRebase can swap some tokens back to the asset. By doing so, there might be a slippage.
    //     By calling redeem, the shares are burnt depending on the asset balance that can be affected by the slippage.
    //     For instance, if the redeemer wants to redeem 10 eth and during withdrawOperations, we exit a UniV3 position (let's say WBTC/asset) and swap
    //     the WBTC back to asset, we would get 5 assets and x WBTC converted to 4.9 assets. The redeemer would get 9.9 assets instead of 10 assets.
    //     when calling redeem, we can only burn shares equivalent to 9.9 assets but the redeemer would still have shares equivalent to 0.1 assets left
    //     in the contract. This would dilute everyone else's shares. To avoid this, we burn the leftOvers shares here.
    //     */
    //     uint256 leftOvers = initialShares -
    //         (initialOwnerShares - balanceOf(owner));
    //     if (leftOvers > 0) {
    //         _burn(owner, leftOvers);
    //     }

    //     return assets;
    // }

    // /* ------------------OVERRIDE IN/OUT FUNCTIONS------------------ */
    // /**
    //  * @dev Overrides ERC4626._deposit to add rebase age validation
    //  * @inheritdoc ERC4626
    //  */
    // function _deposit(
    //     address caller,
    //     address receiver,
    //     uint256 assets,
    //     uint256 shares
    // ) internal virtual override /* onlyValidRebase */ {
    //     super._deposit(caller, receiver, assets, shares);
    // }

    // /**
    //  * @dev Overrides ERC4626._withdraw to add rebase age validation.
    //  * @inheritdoc ERC4626
    //  */
    // function _withdraw(
    //     address caller,
    //     address receiver,
    //     address owner,
    //     uint256 assets,
    //     uint256 shares
    // ) internal virtual override onlyValidRebase {
    //     super._withdraw(caller, receiver, owner, assets, shares);
    // }

    /* ------------------ REBASE ------------------ */

    // function setRebaser(
    //     address newRebaser,
    //     bool enabled
    // ) external onlyOwner {
    //     require(newRebaser != address(0), ZeroAddress());
    //     rebaseOperators[newRebaser] = enabled;
    // }

    /* ------------------FUNCTIONS FOR CUSTOM CALLS------------------ */

    function executeOp(Op calldata op) external {
        if (!opValidator.validateOp(op)) {
            revert OpNotApproved();
        }
        _call(op);
    }

    function executeOpBatch(BatchOp calldata batch) external {
        if (!opValidator.validateBatchedOp(batch)) {
            revert OpNotApproved();
        }

        uint256 length = batch.ops.length;
        for (uint256 i = 0; i < length; ) {
            _call(batch.ops[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _call(Op calldata op) private {
        (bool success, bytes memory result) = op.target.call{value: op.value}(
            op.data
        );

        assembly {
            if iszero(success) {
                revert(add(result, 32), mload(result))
            }
        }

        bytes4 selector;
        if (op.data.length > 4) {
            selector = bytes4(op.data[:4]);
        }

        emit Executed(op.target, op.value, selector);
    }
}
