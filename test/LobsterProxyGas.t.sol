// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolKey as ProxyPoolKey, Currency as ProxyCurrency} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Gas benchmarks for every LobsterProxy swap path. Each scenario is recorded with
/// `vm.snapshotGasLastCall` into `snapshots/LobsterProxyGas.json`, so the effect of a change shows up
/// as a diff of that file.
/// @dev Each scenario is the first and only proxy call of its test, so accounts and storage start
/// cold, as in a real transaction. The committed file comes from a plain `forge test`: each number is the
/// gas of the call itself, as traces show it, without the 21000 base cost and calldata, and before gas
/// refunds. The refund is recorded as `<name>_refund`, so when comparing routes compare the number minus
/// its refund. With `--isolate` the numbers are what a receipt would show: base cost and calldata
/// included, refunds taken off.
///
/// Scenarios are written against a version-neutral {Leg} description; only the `_encode*` helpers
/// know the proxy's calldata format, so the same swaps can be measured across interface changes
/// (they targeted the five single-swap functions and `batchSwap(bytes[])` until those were replaced
/// by `swap(bytes)`).
///
/// Route graph (five pools, both versions, native ETH in the middle):
///   token0 --V3--  token1 --V3--  tokenC
///   token0 --V4--  token1 --V4--  ETH  --V4--  tokenC
contract LobsterProxyGasTest is BatchSwapFixture {
    string constant GROUP = "LobsterProxyGas";

    uint8 constant E_V3_01 = 0;
    uint8 constant E_V3_1C = 1;
    uint8 constant E_V4_01 = 2;
    uint8 constant E_V4_E1 = 3;
    uint8 constant E_V4_EC = 4;
    address constant ETH = address(0);

    /// @notice One swap, independent of how the proxy encodes it
    struct Leg {
        uint8 edge;
        address tokenIn;
        bool exactOut;
        /// @dev amountIn for exact input, amountOut for exact output; ignored when `held`
        uint256 amount;
        /// @dev amountOutMinimum for exact input, amountInMaximum for exact output
        uint256 bound;
        /// @dev Output stays in the proxy for a later leg of the same batch
        bool park;
        /// @dev Exact input only: spends what earlier legs parked
        bool held;
        /// @dev With `held`: the Q128 share of what is parked it spends; 0 means all of it
        uint128 share;
    }

    MockERC20 tokenC;
    ProxyPoolKey nativeKeyC;

    function setUp() public override {
        super.setUp();

        // A third token: V3 token1/tokenC and V4 ETH/tokenC
        tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(address(this), 100_000e18);
        tokenC.approve(address(proxy), type(uint256).max);
        tokenC.approve(address(lpRouter), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token1), address(tokenC), FEE);
        IUniswapV3PoolMinimal pool1C = _v3PoolFor(address(token1), address(tokenC));
        pool1C.initialize(SQRT_PRICE_1_1);
        (address a, address b) =
            address(token1) < address(tokenC) ? (address(token1), address(tokenC)) : (address(tokenC), address(token1));
        _allow(address(this), proxy.v3Key(address(pool1C)), MINT);
        proxy.mint(
            MintParams({
                token0: a,
                token1: b,
                fee: FEE,
                tickLower: -TICK_RANGE,
                tickUpper: TICK_RANGE,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        PoolKey memory kc = _v4CoreKey(ETH, address(tokenC));
        manager.initialize(kc, SQRT_PRICE_1_1);
        _addV4Liquidity(kc, 10_000e18);
        nativeKeyC = _toProxyKey(kc);

        tokenC.mint(user, 10_000e18);
        vm.prank(user);
        tokenC.approve(address(proxy), type(uint256).max);

        _allow(user, proxy.v3Key(address(pool1C)), SWAP);
        _allow(user, proxy.v4Key(nativeKeyC), SWAP);
    }

    // ---------------------------------------------------------------------------------------------
    // Single swaps
    // ---------------------------------------------------------------------------------------------

    function test_gas_single_v3_exactIn() public {
        _measureSingle("single_v3_exactIn", _in(E_V3_01, address(token0), 1e18, false), 0);
    }

    function test_gas_single_v3_exactOut() public {
        _measureSingle("single_v3_exactOut", _out(E_V3_01, address(token1), 1e18, 2e18), 0);
    }

    function test_gas_single_v4_exactIn() public {
        _measureSingle("single_v4_exactIn", _in(E_V4_01, address(token0), 1e18, false), 0);
    }

    function test_gas_single_v4_exactOut() public {
        _measureSingle("single_v4_exactOut", _out(E_V4_01, address(token1), 1e18, 2e18), 0);
    }

    function test_gas_single_v4_exactIn_nativeIn() public {
        _measureSingle("single_v4_exactIn_nativeIn", _in(E_V4_E1, ETH, 1e18, false), 1e18);
    }

    function test_gas_single_v4_exactIn_nativeOut() public {
        _measureSingle("single_v4_exactIn_nativeOut", _in(E_V4_E1, address(token1), 1e18, false), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Batches
    // ---------------------------------------------------------------------------------------------

    /// @notice Two unrelated swaps, one per version, each paid by the vault
    function test_gas_batch_v3_v4_independent() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _in(E_V3_01, address(token0), 1e18, false);
        legs[1] = _in(E_V4_01, address(token0), 1e18, false);
        _measureBatch("batch_v3_v4_independent", legs);
    }

    /// @notice Four unrelated swaps mixing versions and exact input / output
    function test_gas_batch_4_independent_mixed() public {
        Leg[] memory legs = new Leg[](4);
        legs[0] = _in(E_V3_01, address(token0), 1e18, false);
        legs[1] = _out(E_V4_01, address(token0), 1e18, 2e18);
        legs[2] = _out(E_V3_1C, address(token1), 1e18, 2e18);
        legs[3] = _in(E_V4_EC, address(tokenC), 1e18, false);
        _measureBatch("batch_4_independent_mixed", legs);
    }

    /// @notice token0 -V3-> token1 -V3-> tokenC
    function test_gas_batch_chain_v3_v3() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _held(E_V3_1C, address(token1), false);
        _measureBatch("batch_chain_v3_v3", legs);
    }

    /// @notice token0 -V3-> token1 -V4-> ETH
    function test_gas_batch_chain_v3_v4() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _held(E_V4_E1, address(token1), false);
        _measureBatch("batch_chain_v3_v4", legs);
    }

    /// @notice token0 -V4-> token1 -V3-> tokenC
    function test_gas_batch_chain_v4_v3() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _in(E_V4_01, address(token0), 1e18, true);
        legs[1] = _held(E_V3_1C, address(token1), false);
        _measureBatch("batch_chain_v4_v3", legs);
    }

    /// @notice token1 -V4-> ETH -V4-> tokenC
    function test_gas_batch_chain_v4_v4() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _in(E_V4_E1, address(token1), 1e18, true);
        legs[1] = _held(E_V4_EC, ETH, false);
        _measureBatch("batch_chain_v4_v4", legs);
    }

    /// @notice token0 -V3-> token1 -V4-> ETH -V4-> tokenC -V3-> token1
    function test_gas_batch_route_v3_v4_v4_v3() public {
        Leg[] memory legs = new Leg[](4);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _held(E_V4_E1, address(token1), true);
        legs[2] = _held(E_V4_EC, ETH, true);
        legs[3] = _held(E_V3_1C, address(tokenC), false);
        _measureBatch("batch_route_v3_v4_v4_v3", legs);
    }

    /// @notice A split route: token0 -> token1 on both versions, the two outputs merged and spent by one
    /// V4 leg, token1 -V4-> ETH
    function test_gas_batch_split_v3_v4_then_v4() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _in(E_V4_01, address(token0), 1e18, true);
        legs[2] = _held(E_V4_E1, address(token1), false);
        _measureBatch("batch_split_v3_v4_then_v4", legs);
    }

    /// @notice A convergent route: token1 produced on V4 (from token0) and on V3 (from tokenC), the two
    /// outputs merged and spent by one V3 leg, token1 -V3-> token0
    function test_gas_batch_converge_v4_v3_then_v3() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _in(E_V4_01, address(token0), 1e18, true);
        legs[1] = _in(E_V3_1C, address(tokenC), 1e18, true);
        legs[2] = _held(E_V3_01, address(token1), false);
        _measureBatch("batch_converge_v4_v3_then_v3", legs);
    }

    /// @notice Eight chained legs alternating versions, revisiting pools:
    /// token0 -V3-> token1 -V4-> ETH -V4-> tokenC -V3-> token1 -V4-> token0 -V3-> token1 -V4-> ETH -V4-> tokenC
    function test_gas_batch_route_8_legs() public {
        Leg[] memory legs = new Leg[](8);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _held(E_V4_E1, address(token1), true);
        legs[2] = _held(E_V4_EC, ETH, true);
        legs[3] = _held(E_V3_1C, address(tokenC), true);
        legs[4] = _held(E_V4_01, address(token1), true);
        legs[5] = _held(E_V3_01, address(token0), true);
        legs[6] = _held(E_V4_E1, address(token1), true);
        legs[7] = _held(E_V4_EC, ETH, false);
        _measureBatch("batch_route_8_legs", legs);
    }

    /// @notice token0 -V3-> token1, split half on V3 to tokenC and the rest on V3 back to token0: the output
    /// waits in the proxy, which pays both pools. To compare with {test_gas_batch_chain_v3_v3}.
    function test_gas_batch_share_v3_then_v3() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _half(E_V3_1C, address(token1), false);
        legs[2] = _held(E_V3_01, address(token1), false);
        _measureBatch("batch_share_v3_then_v3", legs);
    }

    /// @notice token0 -V3-> token1, split half on V4 to ETH and the rest on V3 to tokenC: the output goes to
    /// the PoolManager, which pays the V3 pool
    function test_gas_batch_share_v4_then_v3() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _half(E_V4_E1, address(token1), false);
        legs[2] = _held(E_V3_1C, address(token1), false);
        _measureBatch("batch_share_v4_then_v3", legs);
    }

    /// @notice token0 -V3-> token1, split half on V3 to tokenC and the rest on V4 to ETH: the output waits in
    /// the proxy, which pays the V3 pool, then the PoolManager. The same route as
    /// {test_gas_batch_share_v4_then_v3} with its consumers swapped, and the costlier order.
    function test_gas_batch_share_v3_then_v4() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _in(E_V3_01, address(token0), 1e18, true);
        legs[1] = _half(E_V3_1C, address(token1), false);
        legs[2] = _held(E_V4_E1, address(token1), false);
        _measureBatch("batch_share_v3_then_v4", legs);
    }

    /// @notice token0 -V4-> token1, split on V4 to ETH, V3 to tokenC, then V4 back to token0: all credit,
    /// and the PoolManager pays the V3 pool
    function test_gas_batch_share_3_consumers_mixed() public {
        Leg[] memory legs = new Leg[](4);
        legs[0] = _in(E_V4_01, address(token0), 1e18, true);
        legs[1] = _half(E_V4_E1, address(token1), false);
        legs[2] = _half(E_V3_1C, address(token1), false);
        legs[3] = _held(E_V4_01, address(token1), false);
        _measureBatch("batch_share_3_consumers_mixed", legs);
    }

    // ---------------------------------------------------------------------------------------------
    // Measuring
    // ---------------------------------------------------------------------------------------------

    function _measureSingle(string memory name, Leg memory leg, uint256 value) internal {
        _measure(name, _encodeSingle(leg), value);
    }

    function _measureBatch(string memory name, Leg[] memory legs) internal {
        _measure(name, _encodeBatch(legs), 0);
    }

    function _measure(string memory name, bytes memory data, uint256 value) internal {
        vm.prank(user);
        (bool ok, bytes memory ret) = address(proxy).call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        vm.snapshotGasLastCall(GROUP, name);
        vm.snapshotValue(
            GROUP, string.concat(name, "_refund"), SafeCast.toUint256(int256(vm.lastCallGas().gasRefunded))
        );

        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy retained tokenC");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    // ---------------------------------------------------------------------------------------------
    // Legs
    // ---------------------------------------------------------------------------------------------

    function _in(uint8 edge, address tokenIn, uint256 amountIn, bool park) internal pure returns (Leg memory) {
        return Leg({
            edge: edge, tokenIn: tokenIn, exactOut: false, amount: amountIn, bound: 0, park: park, held: false, share: 0
        });
    }

    function _held(uint8 edge, address tokenIn, bool park) internal pure returns (Leg memory) {
        return
            Leg({edge: edge, tokenIn: tokenIn, exactOut: false, amount: 0, bound: 0, park: park, held: true, share: 0});
    }

    /// @dev A held leg spending half of what is parked when it runs
    function _half(uint8 edge, address tokenIn, bool park) internal pure returns (Leg memory leg) {
        leg = _held(edge, tokenIn, park);
        leg.share = uint128(1) << 127;
    }

    function _out(uint8 edge, address tokenIn, uint256 amountOut, uint256 maxIn) internal pure returns (Leg memory) {
        return Leg({
            edge: edge,
            tokenIn: tokenIn,
            exactOut: true,
            amount: amountOut,
            bound: maxIn,
            park: false,
            held: false,
            share: 0
        });
    }

    function _edgeTokens(uint8 edge) internal view returns (address, address) {
        if (edge == E_V3_01 || edge == E_V4_01) return (address(token0), address(token1));
        if (edge == E_V3_1C) return (address(token1), address(tokenC));
        if (edge == E_V4_E1) return (ETH, address(token1));
        return (ETH, address(tokenC));
    }

    function _tokenOut(Leg memory leg) internal view returns (address) {
        (address x, address y) = _edgeTokens(leg.edge);
        require(leg.tokenIn == x || leg.tokenIn == y, "leg: token not on this edge");
        return leg.tokenIn == x ? y : x;
    }

    function _isV3(uint8 edge) internal pure returns (bool) {
        return edge == E_V3_01 || edge == E_V3_1C;
    }

    function _v4KeyOf(uint8 edge) internal view returns (ProxyPoolKey memory) {
        return edge == E_V4_01 ? cleanKey : edge == E_V4_E1 ? nativeKey : nativeKeyC;
    }

    function _v3PoolFor(address x, address y) internal view returns (IUniswapV3PoolMinimal) {
        return IUniswapV3PoolMinimal(IUniswapV3FactoryMinimal(v3Factory).getPool(x, y, FEE));
    }

    // ---------------------------------------------------------------------------------------------
    // Encoding: the only part that knows the proxy's calldata format
    // ---------------------------------------------------------------------------------------------

    function _encodeSingle(Leg memory leg) internal view returns (bytes memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = leg;
        return _encodeBatch(legs);
    }

    /// @dev `swap(data)`, with data as {SwapCalldata} packs it
    function _encodeBatch(Leg[] memory legs) internal view returns (bytes memory) {
        SwapCalldata.Leg[] memory packed = new SwapCalldata.Leg[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            packed[i] = _packed(legs[i]);
        }
        return SwapCalldata.call(block.timestamp, packed);
    }

    function _packed(Leg memory leg) internal view returns (SwapCalldata.Leg memory p) {
        p.tokenIn = leg.tokenIn;
        p.tokenOut = _tokenOut(leg);
        p.exactOut = leg.exactOut;
        p.park = leg.park;
        p.held = leg.held;
        p.share = leg.share != 0;
        p.amount = leg.share != 0 ? leg.share : SafeCast.toUint128(leg.amount);
        p.bound = SafeCast.toUint128(leg.bound);
        p.fee = FEE;
        if (!_isV3(leg.edge)) {
            ProxyPoolKey memory key = _v4KeyOf(leg.edge);
            p.v4 = true;
            p.fee = key.fee;
            p.tickSpacing = key.tickSpacing;
            require(
                p.tokenIn == ProxyCurrency.unwrap(key.currency0) || p.tokenIn == ProxyCurrency.unwrap(key.currency1),
                "leg: token not in pool"
            );
        }
    }
}
