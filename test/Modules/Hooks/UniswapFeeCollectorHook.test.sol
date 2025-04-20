// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VaultWithUniswapFeeCollectorHookSetup} from
    "../../Vault/VaultSetups/WithRealModules/VaultWithUniswapFeeCollectorHookSetup.sol";
import {UniswapFeeCollectorHook, BASIS_POINT_SCALE} from "../../../src/Modules/Hooks/UniswapFeeCollectorHook.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/IUniswapV3PoolMinimal.sol";
import {Op} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {DummyUniswapV3PoolMinimal} from "../../Mocks/DummyUniswapV3PoolMinimal.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract UniswapFeeCollectorHookTest is VaultWithUniswapFeeCollectorHookSetup {
    using Math for uint256;

    /*---------------PRE CHECK--------------- */
    function testPreCheckWithWrongSelector() public {
        MockERC20 token0 = MockERC20(address(UniswapFeeCollectorHook(address(vault.hook())).token0()));
        MockERC20 token1 = MockERC20(address(UniswapFeeCollectorHook(address(vault.hook())).token1()));

        // Mint some tokens
        uint256 amount0 = 100;
        token0.mint(address(vault), amount0);
        uint256 amount1 = 112;
        token1.mint(address(vault), amount1);

        // we don't care about the op itself, the preCheck must only check for alice's balance
        Op memory op = Op(
            address(0), // target
            0, // value
            "", // data with selector != uniswapPool.collect selector
            "" // validation data
        );

        bytes memory ctx = vault.hook().preCheck(op, alice /* We don't care about the sender here */ );

        // expect the context to be empty
        assertEq("", ctx);
    }

    function testPreCheckWithRightSelector() public {
        MockERC20 token0 = MockERC20(address(UniswapFeeCollectorHook(address(vault.hook())).token0()));
        MockERC20 token1 = MockERC20(address(UniswapFeeCollectorHook(address(vault.hook())).token1()));

        // Mint some tokens
        uint256 amount0 = 100;
        token0.mint(address(alice), amount0);
        uint256 amount1 = 112;
        token1.mint(address(alice), amount1);

        // we don't care about the op itself, the preCheck must only check for alice's balance
        Op memory op = Op(
            address(UniswapFeeCollectorHook(address(vault.hook())).pool()), // target is the pool
            0, // value
            abi.encodePacked(IUniswapV3PoolMinimal.collect.selector), // data (right selector)
            "" // validation data
        );

        vm.startPrank(alice);
        bytes memory ctx = vault.hook().preCheck(
            op,
            address(0) // we don't care about this in this hook
        );

        // Decode the context
        (uint256 ctxAmount0, uint256 ctxAmount1) = abi.decode(ctx, (uint256, uint256));
        vm.stopPrank();

        // Ensure the values are valid
        assertEq(amount0, ctxAmount0);
        assertEq(amount1, ctxAmount1);
    }

    /*---------------POST CHECK--------------- */
    // Detects a fee collection from the right pool and takes a cut for the fee receiver
    function testTakeFee() public {
        address feeReceiver = UniswapFeeCollectorHook(address(vault.hook())).feeReceiver();

        uint256 initialVaultBalance0 = MockERC20(uniV3MockedPool.token0()).balanceOf(address(vault));
        uint256 initialVaultBalance1 = MockERC20(uniV3MockedPool.token1()).balanceOf(address(vault));
        uint256 feeReceiverInitBalance0 = MockERC20(uniV3MockedPool.token0()).balanceOf(feeReceiver);
        uint256 feeReceiverInitBalance1 = MockERC20(uniV3MockedPool.token1()).balanceOf(feeReceiver);

        // amount to collect from uniswap pool
        uint128 amount0 = 113 ether;
        uint128 amount1 = 763 ether;

        Op memory collectFeeOp = Op(
            address(UniswapFeeCollectorHook(address(vault.hook())).pool()),
            0, // eth value
            abi.encodeWithSelector(
                DummyUniswapV3PoolMinimal.collect.selector,
                address(vault), /* recipient */
                0, /* tickLower - the dummy pool does not care */
                0, /* tickUpper - the dummy pool does not care */
                amount0, /* amount0Requested */
                amount1 /* amount1Requested */
            ),
            ""
        );

        uint256 fee0 = uint256(amount0).mulDiv(
            UniswapFeeCollectorHook(address(vault.hook())).feeBasisPoint(), BASIS_POINT_SCALE, Math.Rounding.Floor
        );
        uint256 fee1 = uint256(amount1).mulDiv(
            UniswapFeeCollectorHook(address(vault.hook())).feeBasisPoint(), BASIS_POINT_SCALE, Math.Rounding.Floor
        );

        vm.expectEmit(true, true, true, true);
        emit UniswapFeeCollectorHook.UniswapPositionPerformanceFee(
            UniswapFeeCollectorHook(address(vault.hook())).feeReceiver(), fee0, fee1
        );
        vault.executeOp(collectFeeOp);

        // ensure the vault balnce is updated with collected uni fess - lobster fees
        assertEq(initialVaultBalance0 + amount0 - fee0, MockERC20(uniV3MockedPool.token0()).balanceOf(address(vault)));

        assertEq(initialVaultBalance1 + amount1 - fee1, MockERC20(uniV3MockedPool.token1()).balanceOf(address(vault)));

        // ensure feeReceiver received the fees
        assertEq(feeReceiverInitBalance0 + fee0, MockERC20(uniV3MockedPool.token0()).balanceOf(feeReceiver));
        assertEq(feeReceiverInitBalance1 + fee1, MockERC20(uniV3MockedPool.token1()).balanceOf(feeReceiver));
    }

    // // Collect the fees from a pool that is not the registered pool
    // function testCallWrongPool() public {}

    // // Calls the right pool but not the collect() function
    // function testCallWrongSelector() public {}

    // /*---------------E2E--------------- */
    // // E2E implementation with the Lobster Vault
    // function testEnd2End() public {}
}
