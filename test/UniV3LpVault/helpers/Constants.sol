// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

library TestConstants {
    // Pool settings
    uint24 constant POOL_FEE = 3000; // 0.3%
    uint160 constant INITIAL_SQRT_PRICE_X96 = 2 ** 96; // 1:1 ratio

    // Test amounts
    uint256 constant INITIAL_BALANCE = 1_000_000 ether;
    uint256 constant SMALL_AMOUNT = 1 ether;
    uint256 constant MEDIUM_AMOUNT = 10 ether;
    uint256 constant LARGE_AMOUNT = 100 ether;

    // Tick settings
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;
    int24 constant TICK_RANGE_NARROW = 6000;
    int24 constant TICK_RANGE_MEDIUM = 12000;
    int24 constant TICK_RANGE_WIDE = 24000;

    // Scaling and percentages
    uint256 constant SCALING_FACTOR = 1e18;
    uint256 constant MAX_SCALED_PERCENTAGE = 100 * SCALING_FACTOR;
    uint256 constant HALF_SCALED_PERCENTAGE = 50 * SCALING_FACTOR;
    uint256 constant QUARTER_SCALED_PERCENTAGE = 25 * SCALING_FACTOR;

    // Time constants
    uint256 constant ONE_DAY = 1 days;
    uint256 constant ONE_WEEK = 7 days;
    uint256 constant ONE_MONTH = 30 days;
    uint256 constant ONE_YEAR = 365 days;

    // Fee rates (in scaled percentage)
    uint256 constant LOW_TVL_FEE = 1 * SCALING_FACTOR; // 1% annual
    uint256 constant MEDIUM_TVL_FEE = 2 * SCALING_FACTOR; // 2% annual
    uint256 constant HIGH_TVL_FEE = 5 * SCALING_FACTOR; // 5% annual

    uint256 constant LOW_PERF_FEE = 1 * SCALING_FACTOR; // 1%
    uint256 constant MEDIUM_PERF_FEE = 2 * SCALING_FACTOR; // 2%
    uint256 constant HIGH_PERF_FEE = 5 * SCALING_FACTOR; // 5%

    // Tolerance for approximate equality checks
    uint256 constant TOLERANCE_LOW = 1e15; // 0.1%
    uint256 constant TOLERANCE_MEDIUM = 1e16; // 1%
    uint256 constant TOLERANCE_HIGH = 5e16; // 5%

    // Address constants
    address constant ZERO_ADDRESS = address(0);
}
