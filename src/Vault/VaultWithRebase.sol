// SPDX-License-Identifier: GPLv3
// pragma solidity ^0.8.28;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {LobsterVault} from "../../Vault/Vault.sol";
// import {NavWithRebase} from "./NavWithRebase.sol";

// /**
//  * @title NavWithRebaseProxy
//  * @author Lobster
//  * @notice This contract is a proxy for the NavWithRebase module.
//  * It is used to rebase and interact with the Vault (deposits, withdrawals, etc.)
//  * in only one transaction.
//  * @dev This contract provides convenience functions to execute vault operations
//  * and rebase actions atomically.
//  */
// contract NavWithRebaseProxy {
//     /**
//      * @notice Reference to the LobsterVault contract
//      * @dev This is immutable and set in the constructor
//      */
//     LobsterVault public immutable vault;

//     /**
//      * @notice Reference to the NavWithRebase module for NAV calculations and rebasing
//      * @dev This is immutable and set in the constructor based on the vault's navModule
//      */
//     NavWithRebase public immutable rebasingNavModule;

//     /**
//      * @notice Reference to the underlying asset token contract
//      * @dev This is immutable and set in the constructor based on the vault's asset
//      */
//     IERC20 public immutable asset;

//     /**
//      * @notice Initializes the proxy with references to the vault and its components
//      * @param _vault Address of the LobsterVault contract
//      * @dev Automatically retrieves and stores references to the rebasingNavModule and asset
//      */
//     constructor(LobsterVault _vault) {
//         vault = _vault;
//         rebasingNavModule = NavWithRebase(address(vault.navModule()));
//         asset = IERC20(vault.asset());
//     }

//     /**
//      * @notice Deposits assets into the vault with optional rebasing before deposit
//      * @param assets Amount of assets to deposit
//      * @param receiver Address to receive the minted shares
//      * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
//      * @return shares Amount of shares minted to receiver
//      * @dev Transfers assets from msg.sender to this contract, then approves and deposits to vault
//      */
//     function deposit(uint256 assets, address receiver, bytes calldata rebaseData) public returns (uint256 shares) {
//         // transfer the assets to the proxy
//         asset.transferFrom(msg.sender, address(this), assets);

//         // approve the vault to spend the assets
//         asset.approve(address(vault), assets);

//         if (rebaseData.length > 0) {
//             rebase(rebaseData);
//         }

//         shares = vault.deposit(assets, receiver);
//     }

//     /**
//      * @notice Withdraws assets from the vault with optional rebasing before withdrawal
//      * @param assets Amount of assets to withdraw
//      * @param receiver Address to receive the withdrawn assets
//      * @param owner Address that owns the shares being burned
//      * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
//      * @return shares Amount of shares burned from owner
//      * @dev Will rebase first if rebaseData is provided, then perform the withdrawal
//      */
//     function withdraw(
//         uint256 assets,
//         address receiver,
//         address owner,
//         bytes calldata rebaseData
//     )
//         public
//         returns (uint256 shares)
//     {
//         if (rebaseData.length > 0) {
//             rebase(rebaseData);
//         }

//         shares = vault.withdraw(assets, receiver, owner);
//     }

//     /**
//      * @notice Mints a specific amount of shares with optional rebasing before minting
//      * @param shares Amount of shares to mint
//      * @param receiver Address to receive the minted shares
//      * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
//      * @return assets Amount of assets pulled from msg.sender
//      * @dev Calculates required assets, transfers them to this contract, then mints shares
//      */
//     function mint(uint256 shares, address receiver, bytes calldata rebaseData) public returns (uint256 assets) {
//         // get the expected assets to mint the shares
//         uint256 expectedAssets = vault.previewMint(shares);

//         // transfer the assets to the proxy
//         asset.transferFrom(msg.sender, address(this), expectedAssets);

//         // approve the vault to spend the assets
//         asset.approve(address(vault), expectedAssets);

//         if (rebaseData.length > 0) {
//             rebase(rebaseData);
//         }

//         assets = vault.mint(shares, receiver);
//     }

//     /**
//      * @notice Redeems shares for assets with optional rebasing before redemption
//      * @param shares Amount of shares to redeem
//      * @param receiver Address to receive the redeemed assets
//      * @param owner Address that owns the shares being burned
//      * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
//      * @return assets Amount of assets transferred to receiver
//      * @dev Will rebase first if rebaseData is provided, then perform the redemption
//      */
//     function redeem(
//         uint256 shares,
//         address receiver,
//         address owner,
//         bytes calldata rebaseData
//     )
//         public
//         returns (uint256 assets)
//     {
//         if (rebaseData.length > 0) {
//             rebase(rebaseData);
//         }

//         assets = vault.redeem(shares, receiver, owner);
//     }

//     /**
//      * @notice Performs a rebase followed by an arbitrary function call
//      * @param rebaseData Encoded rebase parameters (can be empty if no rebase needed)
//      * @param doData Encoded call data containing target address (first 20 bytes) and call data
//      * @return true if both operations succeed
//      * @dev First 20 bytes of doData must be the target address, remainder is the call data
//      * @dev Reverts if the arbitrary call fails
//      */
//     function rebaseAndDo(bytes calldata rebaseData, bytes calldata doData) public returns (bool) {
//         if (rebaseData.length > 0) {
//             rebase(rebaseData);
//         }

//         // decode the data
//         address target = address(bytes20(doData[:20]));
//         bytes memory data = doData[20:];

//         // call the target contract with the data
//         (bool success,) = target.call(data);
//         require(success, "Call failed");

//         return true;
//     }

//     /**
//      * @notice Executes a rebase operation on the NavWithRebase module
//      * @param rebaseData Encoded parameters containing newTotalAssets, rebaseValidUntil, operationData and validationData
//      * @return true if the rebase operation succeeds
//      * @dev Decodes the rebaseData and calls the rebase function on the NavWithRebase module
//      * @dev rebaseData must be encoded as (uint256, uint256, bytes)
//      */
//     function rebase(bytes calldata rebaseData) public returns (bool) {
//         // decode the data
//         (uint256 newTotalAssets, uint256 rebaseValidUntil, bytes memory operationData, bytes memory validationData) =
//             abi.decode(rebaseData, (uint256, uint256, bytes, bytes));

//         rebasingNavModule.rebase(newTotalAssets, rebaseValidUntil, operationData, validationData);

//         return true;
//     }
// }

// pragma solidity ^0.8.28;

// import "forge-std/Test.sol";

// import {INav} from "../../interfaces/modules/INav.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {LobsterVault} from "../../Vault/Vault.sol";
// import {BatchOp} from "../../interfaces/modules/IOpValidatorModule.sol";

// /**
//  * @title NavWithRebase
//  * @author Lobster
//  * @notice This contract is a module for the vault that allows for rebasing of the total assets.
//  * It is used to calculate the total assets of the vault using a manual rebase mechanism.
//  * If the rebase is not valid, it returns the vault's balance of the asset thus allowing users
//  * to withdraw using this balance as a base but occulting any other potential assets. To
//  * ignore the rebase, user need to call the acceptNoRebase function (works for 1 withdrawal then needs to be re-activated).
//  */
// contract NavWithRebase is INav, Ownable {
//     /// @notice The vault's primary asset token
//     IERC20 private vaultAsset;

//     /// @notice Address of the vault contract this module serves
//     address public vault;

//     /// @notice The total assets of the vault (without the vault's assets balance)
//     /// @dev This represents assets that are deployed externally and not held directly in the vault
//     uint256 public totalAssets_;

//     /// @notice Timestamp of the last successful rebase operation
//     uint256 public lastRebaseTimestamp;

//     /// @notice Timestamp until which the current rebase is considered valid
//     /// @dev After this timestamp, totalAssets() falls back to vault's direct balance
//     uint256 public rebaseValidUntil;

//     /// @notice Mapping of addresses authorized to sign rebase operations
//     /// @dev Only addresses with true value can provide valid rebase signatures
//     mapping(address => bool) public rebasers;

//     /// @notice Mapping to track if a user has accepted the no rebase condition: address => approval deadline
//     /// @dev When set, allows users to bypass rebase calculations for withdrawals
//     mapping(address => uint256) public acceptNoRebase;

//     /// @notice Thrown when trying to initialize an already initialized contract
//     error AlreadyInitialized();

//     /// @notice Thrown when a rebase signature is invalid or from unauthorized signer
//     error InvalidSignature();

//     /**
//      * @notice Constructor initializes the contract with owner and initial total assets
//      * @param initialOwner Address that will own this contract
//      * @param initialTotalAssets Starting value for total external assets
//      */
//     constructor(address initialOwner, uint256 initialTotalAssets) Ownable(initialOwner) {
//         lastRebaseTimestamp = block.timestamp;
//         totalAssets_ = initialTotalAssets;
//     }

//     /**
//      * @notice Initializes the contract with vault address and sets up vault asset
//      * @param _vault Address of the LobsterVault contract this module will serve
//      * @dev Can only be called once by the owner
//      */
//     function initialize(address _vault) external onlyOwner {
//         require(vault == address(0), AlreadyInitialized());
//         vault = _vault;
//         vaultAsset = IERC20(LobsterVault(vault).asset());
//     }

//     /**
//      * @inheritdoc INav
//      * @notice Returns the total assets under management by the vault
//      * @dev This function uses a manual rebase mechanism to calculate the total assets.
//      *      If the rebase is valid (current time <= rebaseValidUntil), returns external assets + vault balance.
//      *      If the rebase is expired, returns only the vault's direct token balance.
//      * @return Total assets managed by the vault
//      */
//     function totalAssets() external view returns (uint256) {
//         if (block.timestamp <= rebaseValidUntil) {
//             return totalAssets_ + vaultAsset.balanceOf(vault);
//         } else {
//             return vaultAsset.balanceOf(vault);
//         }
//     }

//     /**
//      * @notice Returns only the assets held locally in the vault contract
//      * @dev This excludes any external assets and only shows the vault's direct token balance
//      * @return The vault's direct balance of the asset token
//      */
//     function totalLocalAssets() external view returns (uint256) {
//         return vaultAsset.balanceOf(vault);
//     }

//     /**
//      * @notice Sets or removes rebaser authorization for an address
//      * @param rebaser Address to authorize or deauthorize
//      * @param isRebaser True to authorize, false to deauthorize
//      * @dev Only authorized rebasers can sign valid rebase operations
//      */
//     function setRebaser(address rebaser, bool isRebaser) external onlyOwner {
//         rebasers[rebaser] = isRebaser;
//     }

//     /**
//      * @notice Updates the total assets value with a signed rebase operation
//      * @param newTotalAssets New value for external total assets
//      * @param validUntil Timestamp until which this rebase remains valid
//      * @param operationData Optional encoded BatchOp to execute during rebase (for unlocking assets)
//      * @param validationData 65-byte signature validating this rebase operation
//      * @dev The signature must be from an authorized rebaser and cover all parameters
//      * @dev If operationData is provided, executes the operations on the vault
//      */
//     function rebase(
//         uint256 newTotalAssets,
//         uint256 validUntil,
//         bytes calldata operationData,
//         bytes calldata validationData
//     )
//         external
//     {
//         require(validUntil >= block.timestamp && validUntil >= rebaseValidUntil, "NavWithRebase: Invalid validUntil");

//         // Ensure the signature is valid and from authorized rebaser
//         address signer = _validateRebaseSignature(validationData, newTotalAssets, validUntil, operationData);
//         require(rebasers[signer], InvalidSignature());

//         // Update state
//         totalAssets_ = newTotalAssets;
//         lastRebaseTimestamp = block.timestamp;
//         rebaseValidUntil = validUntil;

//         // Execute any provided operations (e.g., to unlock assets)
//         if (operationData.length > 0) {
//             BatchOp memory operations = abi.decode(operationData, (BatchOp));
//             LobsterVault(vault).executeOpBatch(operations);
//         }
//     }

//     /**
//      * @notice Validates the signature for a rebase operation
//      * @param validationData 65-byte signature data (v + r + s)
//      * @param newTotalAssets New total assets value being signed
//      * @param validUntil Validity timestamp being signed
//      * @param operationData Operation data being signed
//      * @return signer Address that created the signature
//      */
//     function _validateRebaseSignature(
//         bytes calldata validationData,
//         uint256 newTotalAssets,
//         uint256 validUntil,
//         bytes calldata operationData
//     )
//         internal
//         view
//         returns (address)
//     {
//         // Ensure signature is 65 bytes long (v + r + s)
//         require(validationData.length == 65, InvalidSignature());

//         // Extract the signature components
//         uint8 v;
//         bytes32 r;
//         bytes32 s;
//         assembly {
//             let dataOffset := validationData.offset
//             v := byte(0, calldataload(dataOffset))
//             r := calldataload(add(dataOffset, 1))
//             s := calldataload(add(dataOffset, 33))
//         }

//         // Recover signer from signature and message hash
//         address signer = ecrecover(getMessage(newTotalAssets, validUntil, operationData), v, r, s);
//         require(signer != address(0), InvalidSignature());

//         return signer;
//     }

//     /**
//      * @notice Generates the message hash for signature verification
//      * @param newTotalAssets New total assets value
//      * @param validUntil Validity timestamp
//      * @param operationData Operation data to be executed
//      * @return Message hash
//      * @dev Creates a unique message hash that includes contract address, chain ID, and all parameters
//      */
//     function getMessage(
//         uint256 newTotalAssets,
//         uint256 validUntil,
//         bytes calldata operationData
//     )
//         public
//         view
//         returns (bytes32)
//     {
//         return keccak256(
//             abi.encodePacked(
//                 "\x19Ethereum Signed Message:\n32",
//                 address(this),
//                 block.chainid,
//                 newTotalAssets,
//                 validUntil,
//                 operationData
//             )
//         );
//     }

//     // todo: allow users to acceptNoRebase
// }

// // pragma solidity ^0.8.28;

// // import {VaultWithNavWithRebaseSetup} from "../../Vault/VaultSetups/WithRealModules/VaultWithNavWithRebaseSetup.sol";
// // import {NavWithRebase} from "../../../src/Modules/NavWithRebase/NavWithRebase.sol";
// // import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// // import {MockERC20} from "../../Mocks/MockERC20.sol";

// // contract NavWithRebaseTest is VaultWithNavWithRebaseSetup {
// //     function testTryInitializingTwice() public {
// //         vm.startPrank(owner);
// //         NavWithRebase navModule = NavWithRebase(address(vault.navModule()));
// //         vm.expectRevert(NavWithRebase.AlreadyInitialized.selector);
// //         navModule.initialize(address(vault));
// //         vm.stopPrank();
// //     }

// //     function testValidRebase() public {
// //         NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

// //         // Mint some assets to the vault
// //         MockERC20(vault.asset()).mint(address(vault), 1000 ether);

// //         // Register the rebaser address as a valid rebaser
// //         vm.startPrank(owner);
// //         navModule.setRebaser(rebaser, true);
// //         vm.stopPrank();

// //         uint256 newTotalAssets = 987654321;
// //         uint256 validUntil = block.timestamp + 1 days;

// //         bytes memory operationData = "";
// //         bytes memory validationData = createRebaseSignature(rebaser, newTotalAssets, validUntil, operationData);

// //         vm.prank(address(0)); // Use a different address to ensure it's the signature that's working
// //         navModule.rebase(newTotalAssets, validUntil, operationData, validationData);

// //         assertEq(navModule.totalAssets(), newTotalAssets + IERC20(vault.asset()).balanceOf(address(vault)));
// //         assertEq(navModule.rebaseValidUntil(), validUntil);
// //         assertEq(navModule.lastRebaseTimestamp(), block.timestamp);
// //     }

// //     function testInvalidRebaseSig() public {
// //         NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

// //         // Mint some assets to the vault
// //         MockERC20(vault.asset()).mint(address(vault), 1000 ether);

// //         // Register the rebaser address as a valid rebaser
// //         vm.startPrank(owner);
// //         navModule.setRebaser(rebaser, true);
// //         vm.stopPrank();

// //         uint256 newTotalAssets = 987654321;
// //         uint256 validUntil = block.timestamp + 1 days;

// //         bytes memory operationData = "";
// //         bytes memory validationData = createRebaseSignature(rebaser, newTotalAssets, validUntil, operationData);

// //         // change the last byte of the signature to make it invalid
// //         validationData[validationData.length - 1] = bytes1(uint8(validationData[validationData.length - 1]) + 1);

// //         vm.prank(address(0)); // Use a different address to ensure it's the signature that's working
// //         vm.expectRevert(NavWithRebase.InvalidSignature.selector);
// //         navModule.rebase(newTotalAssets, validUntil, operationData, validationData);
// //     }

// //     function testRebaseThenDeposit() public {
// //         NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

// //         vm.startPrank(bob);
// //         // Bob deposits some assets into the vault (so at the ends the vault has enough tokens to accept alice's withdraw)
// //         uint256 bobDeposit = 2000 ether;
// //         vault.deposit(bobDeposit, bob);

// //         vm.startPrank(alice);
// //         // Alice deposits some assets into the vault
// //         uint256 aliceDeposit = 1000 ether;
// //         vault.deposit(aliceDeposit, alice);

// //         // rebase
// //         vm.startPrank(address(0));
// //         uint256 rebaseValue = aliceDeposit + bobDeposit; //(excluding vault balance) | we double the vault's tvl
// //         uint256 validUntil = block.timestamp + 12 seconds;

// //         bytes memory operationData = "";
// //         bytes memory validationData = createRebaseSignature(rebaser, rebaseValue, validUntil, operationData);

// //         navModule.rebase(rebaseValue, validUntil, operationData, validationData);

// //         // Make sure totalAssets holds
// //         assertEq(navModule.totalAssets(), rebaseValue + IERC20(vault.asset()).balanceOf(address(vault)));
// //         assertEq(navModule.rebaseValidUntil(), validUntil);
// //         assertEq(navModule.lastRebaseTimestamp(), block.timestamp);

// //         vm.startPrank(alice);
// //         // Ensure Alice can withdraw the right amounts. Accept an error of 1 unit
// //         assert(vault.maxWithdraw(alice) >= aliceDeposit * 2 - 1 && vault.maxWithdraw(alice) <= aliceDeposit * 2);
// //         uint256 redeemed = vault.redeem(vault.balanceOf(alice), alice, alice);
// //         // accept 1 unit error
// //         assert(redeemed >= vault.maxRedeem(alice) && redeemed <= aliceDeposit * 2);
// //         vm.stopPrank();
// //     }

// //     // todo: testRebaseThenMint
// //     // todo: testRebaseThenWithdraw
// //     // todo: testRebaseThenRedeem

// //     // todo: test with operationData
// // }
