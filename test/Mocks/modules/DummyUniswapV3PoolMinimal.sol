// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../../../src/interfaces/IUniswapV3PoolMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../MockERC20.sol";

contract DummyUniswapV3PoolMinimal is IUniswapV3PoolMinimal {
    IERC20 public token0_;
    IERC20 public token1_;

    constructor() {
        token0_ = new MockERC20();
        token1_ = new MockERC20();
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
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        external
        returns (uint128 amount0, uint128 amount1)
    {
        // todo
    }
}
