// SPDX-License-Identifier: GNU AGPL v3.0

pragma solidity ^0.8.28;

import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IValidator, Op} from "../interfaces/IValidator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Vault is Ownable2Step, ERC4626 {
    using Math for uint256;

    ERC20 public immutable _asset;
    IValidator public immutable validator;
    address public lobsterAlgorithm;

    // withdrawal penalty in percent
    uint256 public constant WITHDRAWAL_PENALTY = 10; // 10%

    event Executed(address indexed target, uint256 value, bytes data);

    error InitialDepositTooLow(uint256 minimumDeposit);
    error RebaseExpired();
    error OpNotApproved();
    error ZeroAddress();

    // ensure msg.sender is the algorithm
    modifier onlyAlgorithm() {
        require(msg.sender == lobsterAlgorithm, "Vault: only algorithm");
        _;
    }

    // ensure rebase did not expire
    modifier onlyValidRebase() {
        require(validator.rebaseExpiresAt() > block.number, RebaseExpired());
        _;
    }

    constructor(
        address initialOwner,
        ERC20 asset,
        string memory underlyingTokenName,
        string memory underlyingTokenSymbol,
        IValidator validator_,
        address initialLobsterAlgorithm
    )
        Ownable(initialOwner)
        ERC20(underlyingTokenName, underlyingTokenSymbol)
        ERC4626(asset)
    {
        if (initialOwner == address(0) || address(validator_) == address(0)) {
            revert ZeroAddress();
        }
        _asset = asset;
        validator = validator_;
        lobsterAlgorithm = initialLobsterAlgorithm;
    }

    /* ------------------SETTERS------------------ */ // name ok ?

    function totalAssets() public view virtual override returns (uint256) {
        return localTotalAssets() + validator.valueOutsideChain();
    }

    function localTotalAssets() public view virtual returns (uint256) {
        // return _asset.balanceOf(address(this));
        // revert ("Not implemented");
        // todo
        return _asset.balanceOf(address(this));
    }

    /* ------------------IN FUNCTIONS------------------ */
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

    /* ------------------OUT FUNCTIONS------------------ */
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
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ------------------LOBSTER ALGO FUNCTIONS------------------ */

    function executeOp(Op calldata op) external onlyAlgorithm {
        if (!validator.validateOp(op)) {
            revert OpNotApproved();
        }
        _call(op);
    }

    function executeOpBatch(Op[] calldata ops) external onlyAlgorithm {
        if (!validator.validateBatchedOp(ops)) {
            revert OpNotApproved();
        }

        uint256 length = ops.length;
        for (uint256 i = 0; i < length; ) {
            _call(ops[i]);
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

        emit Executed(op.target, op.value, op.data);
    }

    /* ---------------------------------------------------- */

    receive() external payable {
        revert("Vault: not payable");
    }
}
