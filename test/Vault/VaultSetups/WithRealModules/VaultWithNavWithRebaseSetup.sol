// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;
import "forge-std/Test.sol";

import {LobsterVault} from "../../../../src/Vault/Vault.sol";
import {Counter} from "../../../Mocks/Counter.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {VaultTestUtils} from "../VaultTestUtils.sol";
import {UniswapFeeCollectorHook} from "../../../../src/Modules/Hooks/UniswapFeeCollectorHook.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
import {DummyUniswapV3PoolMinimal} from "../../../Mocks/DummyUniswapV3PoolMinimal.sol";
import {DummyHook} from "../../../Mocks/modules/DummyHook.sol";
import {NavWithRebase} from "../../../../src/Modules/NavWithRebase/navWithRebase.sol";

// Vault base setup with validator function to be used in other test files
contract VaultWithNavWithRebaseSetup is VaultTestUtils {
    DummyUniswapV3PoolMinimal uniV3MockedPool;
    address public rebaser;
    uint256 public rebaserPrivateKey;
    uint256 public notRebaserPrivateKey;
    address public notRebaser;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");
        rebaserPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        rebaser = vm.addr(rebaserPrivateKey);
        notRebaserPrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        notRebaser = vm.addr(notRebaserPrivateKey);
        console.log("rebaser: ", rebaser);
        // module instantiation
        IHook hook = new DummyHook();
        IOpValidatorModule opValidator = new DummyValidator();
        IVaultFlowModule vaultOperations = IVaultFlowModule(address(0));
        NavWithRebase navModuleWithRebase = new NavWithRebase(owner, 0);
        INav navModule = navModuleWithRebase;

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterVault(
            owner,
            asset,
            "Vault Token",
            "vTKN",
            feeCollector,
            opValidator,
            hook,
            navModule,
            vaultOperations,
            0,
            0,
            0
        );

        vm.startPrank(owner);
        // initialize nav module
        navModuleWithRebase.initialize(address(vault));
        // set the rebaser
        navModuleWithRebase.setRebaser(rebaser, true);
        vm.stopPrank();

        // Setup initial state
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function createRebaseSignature(
        address signer,
        uint256 newTotalAssets,
        uint256 validUntil,
        bytes memory operationData
    ) internal view returns (bytes memory signature) {
        // Get the message hash as expected by the contract
        bytes32 msgHash = NavWithRebase(address(vault.navModule())).getMessage(
            newTotalAssets,
            validUntil,
            operationData
        );

        uint256 privateKey = 0;
        if (signer == rebaser) {
            privateKey = rebaserPrivateKey;
        } else if (signer == notRebaser) {
            privateKey = notRebaserPrivateKey;
        } else {
            revert("Invalid signer");
        }
        // Sign the message hash using the private key of the signer
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);

        console.log("ini v", v);
        console.log("ini r", uint256(r));
        console.log("ini s", uint256(s));
        // Create the signature data in the format the contract expects
        signature = abi.encodePacked(v,r,s);
    }
}
