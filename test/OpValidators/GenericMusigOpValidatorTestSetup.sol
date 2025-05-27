// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {GenericMuSigOpValidator} from "../../src/Modules/OpValidators/GenericMuSigOpValidator.sol";
import {WhitelistedCall, SelectorAndChecker, Signer, Op} from "../../src/interfaces/modules/IOpValidatorModule.sol";
import {SEND_ETH, CALL_FUNCTIONS, NO_PARAMS_CHECKS_ADDRESS} from "../../src/Modules/OpValidators/constants.sol";
import {Counter} from "../Mocks/Counter.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract GenericMuSigOpValidatorTestSetup is Test {
    using MessageHashUtils for bytes32;

    Counter public counter;

    // anvil private keys
    uint256 public constant signer1 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 public constant signer2 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 public constant signer3 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 public constant notValidatorSigner = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    Signer[] private signers;

    function setUp() public {
        // Deploy a test contract
        counter = new Counter();

        // Create a list of signers
        signers = new Signer[](3);
        signers[0] = Signer({signer: vm.addr(signer1), weight: 1});
        signers[1] = Signer({signer: vm.addr(signer2), weight: 1});
        signers[2] = Signer({signer: vm.addr(signer3), weight: 2});
    }

    function setupValidator(
        WhitelistedCall[] memory whitelistedCalls,
        address vault
    )
        public
        returns (GenericMuSigOpValidator)
    {
        // allow transfer of erc20 to bob's address
        SelectorAndChecker[] memory selectorAndChecker = new SelectorAndChecker[](1);
        selectorAndChecker[0] =
            SelectorAndChecker({selector: counter.increment.selector, paramsValidator: NO_PARAMS_CHECKS_ADDRESS});

        // Deploy the GenericMuSigOpValidator contract
        GenericMuSigOpValidator validator = new GenericMuSigOpValidator(whitelistedCalls, signers, 2);

        // Set the vault address
        bytes32 message =
            keccak256(abi.encodePacked("GenericMuSigOpValidator_SET_VAULT", vault)).toEthSignedMessageHash();
        uint256[] memory privateKeys = new uint256[](3);
        privateKeys[0] = signer1;
        privateKeys[1] = signer2;
        privateKeys[2] = signer3;
        bytes memory signatures = multiSign(privateKeys, message);

        validator.setVault(vault, signatures);

        return validator;
    }

    function multiSign(uint256[] memory privateKeys, bytes32 message) internal pure returns (bytes memory) {
        uint256 privateKeysLength = privateKeys.length;

        bytes[] memory signatures = new bytes[](privateKeysLength);

        for (uint256 j = 0; j < privateKeysLength; j++) {
            // Sign the message with the private key
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKeys[j], message);

            // Store the signature
            signatures[j] = abi.encodePacked(r, s, v);
        }

        // Concatenate the signatures
        uint256 sigLenth = signatures.length;
        bytes memory concatenatedSignatures;
        for (uint256 i = 0; i < sigLenth; i++) {
            concatenatedSignatures = abi.encodePacked(concatenatedSignatures, signatures[i]);
        }
        return concatenatedSignatures;
    }
}
