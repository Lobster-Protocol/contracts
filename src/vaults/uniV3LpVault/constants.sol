// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

// Constant used to scale percentage values (represents 1.0 or 100% in fixed-point arithmetic)
uint256 constant SCALING_FACTOR = 1e18;

// Maximum percentage value scaled (100% scaled, equals 100 * 1e18)
uint256 constant MAX_SCALED_PERCENTAGE = 100 * SCALING_FACTOR;

// Maximum fee that can be charged (30% scaled, equals 30 * 1e18)
uint256 constant MAX_FEE_SCALED = 30 * SCALING_FACTOR;

// Time window for TWAP (Time-Weighted Average Price) calculations - 7 days in seconds
uint32 constant TWAP_SECONDS_AGO = 7 days;
