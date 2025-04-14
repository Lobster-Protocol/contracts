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

    // /**
    //  * Override ERC4626.totalAssets to take into account the value outside the chain
    //  */
    // function totalAssets() public view virtual override returns (uint256) {
    //     // todo: use module for this
    //     // return localTotalAssets() + valueOutsideVault;
    // }

    // returns the assets owned by the vault on this blockchain (only the assets in the supported protocols / contracts)
    // value returned is the corresponding ether value
    function localTotalAssets() public view virtual returns (uint256) {
        // todo: use module for this
        // todo: get values from all supported protocols
        return IERC20(asset()).balanceOf(address(this));
    }

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
