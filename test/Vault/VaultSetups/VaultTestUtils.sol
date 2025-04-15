// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {LobsterVault, Op} from "../../../src/Vault/Vault.sol";
import {Counter} from "../../Mocks/Counter.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE, SECONDS_PER_YEAR} from "../../../src/Vault/Constants.sol";
import {IHook} from "../../../src/interfaces/IHook.sol";
import {IOpValidatorModule} from "../../../src/interfaces/modules/IOpValidatorModule.sol";

enum RebaseType {
    DEPOSIT,
    MINT,
    WITHDRAW,
    REDEEM
}

// Vault base setup & utils function to be used in other test files
contract VaultTestUtils is Test {
    using Math for uint256;

    LobsterVault public vault;
    MockERC20 public asset;
    Counter public counter;
    address public owner;
    address public alice;
    address public bob;
    address public lobsterAlgorithm;
    address public lobsterRebaser;
    uint256 public lobsterRebaserPrivateKey;

    // fees
    address public feeCollector;
    uint256 public entryFeeBasisPoints = 0;
    uint256 public exitFeeBasisPoints = 0;

    /* -------------- Helper Functions -------------- */
    function getValidRebaseData(
        address vault_,
        uint256 valueOutsideVault,
        uint256 expirationBlock,
        uint256 minEthAmountToRetrieve,
        RebaseType rebaseType,
        bytes memory withdrawOperations
    )
        public
        view
        returns (bytes memory)
    {
        bytes32 messageToBeSigned = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(valueOutsideVault, expirationBlock, withdrawOperations, block.chainid, vault))
        );

        // sign the data using the private key of the rebaser
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lobsterRebaserPrivateKey, messageToBeSigned);

        // Concatenate the signature components
        bytes memory signature = abi.encodePacked(r, s, v);

        return abi.encodePacked(
            rebaseType == RebaseType.DEPOSIT || rebaseType == RebaseType.MINT ? hex"00" : hex"01",
            minEthAmountToRetrieve,
            vault_,
            abi.encode(valueOutsideVault, expirationBlock, withdrawOperations, signature)
        );
    }

    function setEntryFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setEntryFee(fee);
        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee
        vault.enforceNewEntryFee();
        vm.stopPrank();

        return true;
    }

    function setExitFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setExitFee(fee);
        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee
        vault.enforceNewExitFee();
        vm.stopPrank();

        return true;
    }

    function setManagementFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setManagementFee(fee);
        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee
        vault.enforceNewManagementFee();
        vm.stopPrank();

        return true;
    }

    function setPerformanceFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setPerformanceFee(fee);
        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee
        vault.enforceNewPerformanceFee();
        vm.stopPrank();

        return true;
    }

    function computeFees(uint256 amount, uint256 fee) public pure returns (uint256) {
        return amount.mulDiv(fee, BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    function computeManagementFees(
        uint256 vaultShares,
        uint256 fee, // basis point
        uint256 duration
    )
        public
        pure
        returns (uint256)
    {
        return (vaultShares * fee).mulDiv(duration, (BASIS_POINT_SCALE * SECONDS_PER_YEAR), Math.Rounding.Ceil);
    }

    function computePerformanceFees(
        uint256 vaultShares,
        uint256 fee, // basis point
        uint256 duration
    )
        public
        pure
        returns (uint256)
    {
        // todo
        revert("Not implemented");
    }

    // check if we are in a delegate call
    function amIDelegated() public view returns (bool) {
        // Get the address where the code is actually stored
        address codeAddress;
        assembly {
            codeAddress := extcodesize(address())
        }

        // If the code address is different from address(this), we're in a delegatecall
        return codeAddress != address(this);
    }
}
