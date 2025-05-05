// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {MockERC20} from "./MockERC20.sol";

contract DummyUniswapV3PoolMinimal is IUniswapV3PoolMinimal {
    MockERC20 public token0_;
    MockERC20 public token1_;

    constructor() {
        token0_ = new MockERC20();
        token1_ = new MockERC20();
    }

    function initialize(uint160) external pure {
        revert("initialize: Not implemented");
    }

    function factory() external pure returns (address) {
        revert("factory: Not implemented");
    }

    function feeGrowthGlobal0X128() external pure returns (uint256) {
        revert("feeGrowthGlobal0X128: Not implemented");
    }

    function feeGrowthGlobal1X128() external pure returns (uint256) {
        revert("feeGrowthGlobal1X128: Not implemented");
    }

    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        revert("ticks: Not implemented");
    }

    function slot0()
        external
        pure
        returns (
            uint160, /* sqrtPriceX96 */
            int24, /* tick */
            uint16, /* observationIndex */
            uint16, /* observationCardinality */
            uint16, /* observationCardinalityNext */
            uint8, /* feeProtocol */
            bool /* unlocked */
        )
    {
        revert("slot0 not implemented");
    }

    function token0() external view returns (address) {
        return address(token0_);
    }

    function token1() external view returns (address) {
        return address(token1_);
    }

    function collect(
        address recipient,
        int24, /* tickLower */
        int24, /* tickUpper */
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        external
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested;
        amount1 = amount1Requested;

        // Mint a pseudo random amount of tokens 0 & 1 to the recipient
        token0_.mint(recipient, amount0);
        token1_.mint(recipient, amount1);
    }

    function observe(uint32[] memory) external pure returns (int56[] memory, uint160[] memory) {
        revert("observe not implemented");
    }
}
