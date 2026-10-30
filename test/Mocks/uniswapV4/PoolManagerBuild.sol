// SPDX-License-Identifier: GPL-3.0
// v4-core pins its PoolManager to exactly 0.8.26, while the Lobster contracts are built with 0.8.28
// (0.8.26 crashes on them, "Assembly exception for bytecode"). No file may import both. This file is
// the only one that imports the PoolManager source: it makes a full `forge build` produce the 0.8.26
// artifact that bytecodes/poolManager.sol is copied from, and that PoolManagerBytecode.t.sol checks
// the committed copy against.
pragma solidity =0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
