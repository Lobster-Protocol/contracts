// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import "forge-std/Test.sol";

import {LobsterProxy} from "../src/LobsterProxy.sol";
import {PoolRegistry} from "../src/base/PoolRegistry.sol";
import {V4LiquidityOp} from "../src/UniswapV4LiquidityProxy.sol";
import {SwapType} from "../src/UniswapBatchSwapProxy.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {PoolKey, Currency, IHooks} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {MintParams, MintCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams,
    SwapCallbackData
} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
// `^0.8.0`, unlike UniswapV3Infra (`^0.8.28`), so a real V3 factory can share a 0.8.26 unit with
// LobsterProxy.
import {FACTORY_BYTECODE} from "./Mocks/uniswapV3/bytecodes/factory.sol";
// NOTE: solmate's mock, not test/Mocks/MockERC20.sol, which requires ^0.8.28.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice A token that, the first time it is transferred to `trigger`, tries to call `setPools` on
/// the proxy, and records what happened.
contract SetPoolsOnTransfer is MockERC20 {
    address public proxy;
    address public trigger;
    bool public armed;
    bool public attackSucceeded;
    bytes public attackRevertData;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function arm(address _proxy, address _trigger) external {
        (proxy, trigger, armed) = (_proxy, _trigger, true);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && to == trigger) {
            armed = false;
            bytes32[] memory pools = new bytes32[](1);
            pools[0] = bytes32(uint256(0xBEEF));
            uint8[] memory permissions = new uint8[](1);
            permissions[0] = 3;
            (attackSucceeded, attackRevertData) =
                proxy.call(abi.encodeCall(PoolRegistry.setPools, (pools, permissions)));
        }
        return super.transfer(to, amount);
    }
}

/// @notice LobsterProxy: deny by default, per-vault pool registry, recipient is always the vault.
contract LobsterProxyTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96, price = 1
    uint24 constant FEE = 3000; // the vault's pool
    uint24 constant OTHER_FEE = 500; // same tokens, a pool the vault never registers
    int24 constant RANGE = 6000; // a multiple of both tick spacings (60 and 10)
    uint8 constant MINT = 1;
    uint8 constant SWAP = 2;
    uint8 constant BOTH = 3;

    LobsterProxy lobster;
    address factory;
    MockERC20 token0;
    MockERC20 token1;

    address vaultA = makeAddr("vaultA");
    address vaultB = makeAddr("vaultB");

    function setUp() public virtual {
        bytes memory code = FACTORY_BYTECODE;
        address f;
        assembly {
            f := create(0, add(code, 0x20), mload(code))
        }
        require(f != address(0), "v3 factory deployment failed");
        factory = f;

        // This suite covers the V3 surface; the V4 and batch paths are covered, against a real PoolManager,
        // in LobsterProxyV4Batch.t.sol. Here the PoolManager is never reached.
        // The V3 paths never touch the PoolManager, so any address will do here
        lobster = new LobsterProxy(factory, makeAddr("poolManager"));

        token0 = new MockERC20("Token A", "TKA", 18);
        token1 = new MockERC20("Token B", "TKB", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Two pools on the same pair: the vault's (FEE) and one it never registers (OTHER_FEE)
        token0.mint(address(this), 100_000e18);
        token1.mint(address(this), 100_000e18);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(lobster), type(uint256).max);
        _createPoolWithLiquidity(address(token0), address(token1), FEE);
        _createPoolWithLiquidity(address(token0), address(token1), OTHER_FEE);

        address[2] memory vaults = [vaultA, vaultB];
        for (uint256 i = 0; i < 2; i++) {
            token0.mint(vaults[i], 10_000e18);
            token1.mint(vaults[i], 10_000e18);
            vm.startPrank(vaults[i]);
            token0.approve(address(lobster), type(uint256).max);
            token1.approve(address(lobster), type(uint256).max);
            vm.stopPrank();
            // Price bands allowing any price, so the registry checks are what these tests exercise.
            // A band grants nothing by itself: without PERMISSION_MINT a mint is still refused.
            _anyPrice(vaults[i], _key(FEE));
            _anyPrice(vaults[i], _key(OTHER_FEE));
        }
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev The pool's liquidity comes from this contract, through the proxy like any vault's: it
    /// registers the pool for itself first. Vaults A and B are unaffected.
    function _createPoolWithLiquidity(address a, address b, uint24 fee) internal {
        address pool = IUniswapV3FactoryMinimal(factory).createPool(a, b, fee);
        IUniswapV3PoolMinimal(pool).initialize(SQRT_PRICE_1_1);
        _set(address(this), lobster.v3Key(pool), MINT);
        _anyPrice(address(this), lobster.v3Key(pool));
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        lobster.mint(
            MintParams({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: -RANGE,
                tickUpper: RANGE,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _pool(uint24 fee) internal view returns (address) {
        return PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(address(token0), address(token1), fee));
    }

    function _key(uint24 fee) internal view returns (bytes32) {
        return lobster.v3Key(_pool(fee));
    }

    function _set(address vault, bytes32 key, uint8 permissions) internal {
        bytes32[] memory pools = new bytes32[](1);
        pools[0] = key;
        uint8[] memory perms = new uint8[](1);
        perms[0] = permissions;
        vm.prank(vault);
        lobster.setPools(pools, perms);
    }

    /// @dev `vault`'s price band for `key` set to the whole tick range
    function _anyPrice(address vault, bytes32 key) internal {
        vm.prank(vault);
        lobster.setPriceBand(key, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    function _mintParams(uint24 fee, address to) internal view returns (MintParams memory) {
        return MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: fee,
            tickLower: -600,
            tickUpper: 600,
            amount0Desired: 10e18,
            amount1Desired: 10e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: to,
            deadline: block.timestamp
        });
    }

    function _exactIn(bool zeroForOne, uint24 fee, address to) internal view returns (ExactInputSingleParams memory) {
        (address tIn, address tOut) =
            zeroForOne ? (address(token0), address(token1)) : (address(token1), address(token0));
        return ExactInputSingleParams({
            tokenIn: tIn,
            tokenOut: tOut,
            fee: fee,
            recipient: to,
            deadline: block.timestamp,
            amountIn: 1e18,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    function _exactOut(
        bool zeroForOne,
        uint24 fee,
        address to,
        uint256 amountOut
    )
        internal
        view
        returns (ExactOutputSingleParams memory)
    {
        (address tIn, address tOut) =
            zeroForOne ? (address(token0), address(token1)) : (address(token1), address(token0));
        return ExactOutputSingleParams({
            tokenIn: tIn,
            tokenOut: tOut,
            fee: fee,
            recipient: to,
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
    }

    /// @dev Calldata for each of the three checked V3 entry points
    function _calls(uint24 fee, address to) internal view returns (bytes[3] memory c) {
        c[0] = abi.encodeCall(LobsterProxy.mint, (_mintParams(fee, to)));
        c[1] = abi.encodeCall(LobsterProxy.exactInputSingle, (_exactIn(true, fee, to)));
        c[2] = abi.encodeCall(LobsterProxy.exactOutputSingle, (_exactOut(true, fee, to, 1e18)));
    }

    /// @dev Expects every checked entry point, called by `caller`, to revert with `reason`
    function _expectAllRevert(address caller, uint24 fee, address to, bytes4 reason) internal {
        bytes[3] memory c = _calls(fee, to);
        for (uint256 i = 0; i < c.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, string.concat("entry point ", vm.toString(i), " did not revert"));
            assertEq(ret, abi.encodeWithSelector(reason), string.concat("entry point ", vm.toString(i)));
        }
    }

    function _balances(address who) internal view returns (uint256[4] memory b) {
        address p = _pool(FEE);
        b[0] = token0.balanceOf(who);
        b[1] = token1.balanceOf(who);
        b[2] = token0.balanceOf(p);
        b[3] = token1.balanceOf(p);
    }

    // ---------------------------------------------------------------------------
    // Deny by default
    // ---------------------------------------------------------------------------

    function test_unregisteredCaller_isDeniedEverywhere() public {
        _expectAllRevert(vaultB, FEE, vaultB, IProxyErrors.PoolNotAllowed.selector);
    }

    function test_unregisteredPool_isDeniedEverywhere() public {
        _set(vaultA, _key(FEE), BOTH);
        _expectAllRevert(vaultA, OTHER_FEE, vaultA, IProxyErrors.PoolNotAllowed.selector);
    }

    function test_registrationIsPerVault() public {
        _set(vaultA, _key(FEE), BOTH);
        _expectAllRevert(vaultB, FEE, vaultB, IProxyErrors.PoolNotAllowed.selector);

        // vault B's own writes never touch vault A's entries
        _set(vaultB, _key(FEE), 0);
        assertEq(lobster.permissionsOf(vaultA, _key(FEE)), BOTH, "vault B changed vault A's entry");
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    function test_recipientMustBeTheCaller() public {
        _set(vaultA, _key(FEE), BOTH);
        address[5] memory others = [vaultB, makeAddr("someone"), address(0), address(lobster), address(2)];
        for (uint256 i = 0; i < others.length; i++) {
            _expectAllRevert(vaultA, FEE, others[i], IProxyErrors.RecipientMustBeCaller.selector);
        }
    }

    /// @dev The recipient check comes first, as specified
    function test_recipientIsCheckedBeforeTheRegistry() public {
        _expectAllRevert(vaultB, OTHER_FEE, vaultA, IProxyErrors.RecipientMustBeCaller.selector);
    }

    function test_mintOnlyPool_cannotBeSwapped() public {
        _set(vaultA, _key(FEE), MINT);
        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
        vm.stopPrank();
    }

    function test_swapOnlyPool_cannotBeMinted() public {
        _set(vaultA, _key(FEE), SWAP);
        vm.startPrank(vaultA);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.stopPrank();
    }

    function test_oneRegistration_swapsInBothDirections() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256 t0 = token0.balanceOf(vaultA);
        uint256 t1 = token1.balanceOf(vaultA);

        vm.startPrank(vaultA);
        uint256 out01 = lobster.exactInputSingle(_exactIn(true, FEE, vaultA)); // token0 -> token1
        uint256 out10 = lobster.exactInputSingle(_exactIn(false, FEE, vaultA)); // token1 -> token0
        vm.stopPrank();

        assertEq(token0.balanceOf(vaultA), t0 - 1e18 + out10, "token0 flows");
        assertEq(token1.balanceOf(vaultA), t1 + out01 - 1e18, "token1 flows");
    }

    function test_deadlineIsStillEnforced() public {
        _set(vaultA, _key(FEE), BOTH);
        MintParams memory m = _mintParams(FEE, vaultA);
        m.deadline = block.timestamp - 1;
        ExactInputSingleParams memory ei = _exactIn(true, FEE, vaultA);
        ei.deadline = block.timestamp - 1;

        vm.startPrank(vaultA);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        lobster.mint(m);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        lobster.exactInputSingle(ei);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Registry
    // ---------------------------------------------------------------------------

    function test_updateAndRemove() public {
        bytes32 p = _key(FEE);

        _set(vaultA, p, MINT);
        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
        vm.stopPrank();

        _set(vaultA, p, SWAP); // overwrite, not merge
        vm.startPrank(vaultA);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.stopPrank();
        (bytes32[] memory pools, uint8[] memory perms) = lobster.poolsOf(vaultA);
        assertEq(pools.length, 1, "update duplicated the entry");
        assertEq(perms[0], SWAP);

        _set(vaultA, p, 0); // remove
        _expectAllRevert(vaultA, FEE, vaultA, IProxyErrors.PoolNotAllowed.selector);
        (pools,) = lobster.poolsOf(vaultA);
        assertEq(pools.length, 0, "removed pool still listed");
        assertEq(lobster.permissionsOf(vaultA, p), 0);
    }

    /// @notice Random add / update / remove sequences, including the same pool twice in one call:
    /// `poolsOf` and `permissionsOf` must always match a simple model, with no duplicates and no
    /// zero entries, and vault B must never be affected.
    function testFuzz_poolsOf_staysConsistent(uint256 seed, uint256 rounds) public {
        // Two real V3 keys, an arbitrary V3-shaped key, and two V4-shaped keys (MINT not allowed on those)
        bytes32[5] memory candidates =
            [_key(FEE), _key(OTHER_FEE), bytes32(uint256(0x1111)), keccak256("v4 pool a"), keccak256("v4 pool b")];
        uint8[5] memory model;

        uint256 n = bound(rounds, 1, 12);
        for (uint256 r = 0; r < n; r++) {
            uint256 k = bound(uint256(keccak256(abi.encode(seed, r))), 1, 4);
            bytes32[] memory pools = new bytes32[](k);
            uint8[] memory perms = new uint8[](k);
            for (uint256 j = 0; j < k; j++) {
                uint256 x = uint256(keccak256(abi.encode(seed, r, j)));
                uint256 c = x % 5;
                pools[j] = candidates[c];
                perms[j] = c < 3 ? uint8((x >> 8) % 4) : uint8(((x >> 8) % 2) * SWAP);
                model[c] = perms[j]; // applied in order: the last value for a key wins
            }
            vm.prank(vaultA);
            lobster.setPools(pools, perms);
            _assertRegistryMatches(candidates, model);
        }

        (bytes32[] memory others,) = lobster.poolsOf(vaultB);
        assertEq(others.length, 0, "vault B was affected");
    }

    function _assertRegistryMatches(bytes32[5] memory candidates, uint8[5] memory model) internal view {
        (bytes32[] memory listed, uint8[] memory perms) = lobster.poolsOf(vaultA);
        uint256 expected;
        for (uint256 c = 0; c < 5; c++) {
            assertEq(lobster.permissionsOf(vaultA, candidates[c]), model[c], "permissionsOf");
            if (model[c] != 0) expected++;
        }
        assertEq(listed.length, expected, "poolsOf length");
        assertEq(perms.length, listed.length, "poolsOf arrays differ in length");
        for (uint256 i = 0; i < listed.length; i++) {
            bool found;
            for (uint256 c = 0; c < 5; c++) {
                if (candidates[c] == listed[i]) {
                    found = true;
                    assertEq(perms[i], model[c], "poolsOf permission");
                }
            }
            assertTrue(found, "poolsOf lists an unknown key");
            assertGt(perms[i], 0, "poolsOf lists a removed key");
            for (uint256 j = 0; j < i; j++) {
                assertTrue(listed[j] != listed[i], "poolsOf lists a key twice");
            }
        }
    }

    function test_setPools_lengthMismatch_reverts() public {
        bytes32[] memory pools = new bytes32[](2);
        uint8[] memory perms = new uint8[](1);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.LengthMismatch.selector);
        lobster.setPools(pools, perms);
    }

    function testFuzz_setPools_invalidBits_revert(uint8 bits) public {
        vm.assume(bits & ~BOTH != 0);
        bytes32[] memory pools = new bytes32[](1);
        pools[0] = _key(FEE);
        uint8[] memory perms = new uint8[](1);
        perms[0] = bits;
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.InvalidPermissions.selector);
        lobster.setPools(pools, perms);
    }

    /// @notice One bad entry reverts the whole call: nothing before it is written
    function test_setPools_isAtomic() public {
        bytes32[] memory pools = new bytes32[](2);
        pools[0] = _key(FEE);
        pools[1] = _key(OTHER_FEE);
        uint8[] memory perms = new uint8[](2);
        perms[0] = BOTH;
        perms[1] = 4;
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.InvalidPermissions.selector);
        lobster.setPools(pools, perms);

        assertEq(lobster.permissionsOf(vaultA, _key(FEE)), 0, "first entry was written");
        (bytes32[] memory listed,) = lobster.poolsOf(vaultA);
        assertEq(listed.length, 0);
    }

    function test_setPools_emitsOneEventPerPool() public {
        bytes32[] memory pools = new bytes32[](2);
        pools[0] = _key(FEE);
        pools[1] = _key(OTHER_FEE);
        uint8[] memory perms = new uint8[](2);
        perms[0] = MINT;
        perms[1] = 0;

        vm.expectEmit(address(lobster));
        emit PoolRegistry.PoolPermissionsSet(vaultA, pools[0], MINT);
        vm.expectEmit(address(lobster));
        emit PoolRegistry.PoolPermissionsSet(vaultA, pools[1], 0);
        vm.prank(vaultA);
        lobster.setPools(pools, perms);
    }

    // ---------------------------------------------------------------------------
    // Happy paths: exactly the expected tokens move
    // ---------------------------------------------------------------------------

    /// @dev One balance went from `before` to `afterwards` by gaining `gain` and losing `loss`
    function _assertMoved(
        uint256 before,
        uint256 afterwards,
        uint256 gain,
        uint256 loss,
        string memory what
    )
        internal
        pure
    {
        assertEq(afterwards + loss, before + gain, what);
    }

    /// @notice A registered vault's mint and swaps move exactly what they report: the vault pays the
    /// pool, the pool pays the vault, the position is the vault's, and the proxy keeps nothing
    function test_happyPaths_moveExactlyTheReportedAmounts() public {
        _set(vaultA, _key(FEE), BOTH);
        uint256[4] memory b = _balances(vaultA); // vault token0, token1; pool token0, token1

        vm.prank(vaultA);
        (uint256 paid0, uint256 paid1) = lobster.mint(_mintParams(FEE, vaultA));
        uint256[4] memory a = _balances(vaultA);
        assertGt(paid0, 0);
        assertGt(paid1, 0);
        _assertMoved(b[0], a[0], 0, paid0, "mint: vault token0");
        _assertMoved(b[1], a[1], 0, paid1, "mint: vault token1");
        _assertMoved(b[2], a[2], paid0, 0, "mint: pool token0");
        _assertMoved(b[3], a[3], paid1, 0, "mint: pool token1");
        (uint128 liquidity,,,,) =
            IUniswapV3PoolMinimal(_pool(FEE)).positions(keccak256(abi.encodePacked(vaultA, int24(-600), int24(600))));
        assertGt(liquidity, 0, "the vault does not own the position");

        b = a;
        vm.prank(vaultA);
        uint256 out = lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
        a = _balances(vaultA);
        assertGt(out, 0);
        _assertMoved(b[0], a[0], 0, 1e18, "exactIn: vault token0");
        _assertMoved(b[1], a[1], out, 0, "exactIn: vault token1");
        _assertMoved(b[2], a[2], 1e18, 0, "exactIn: pool token0");
        _assertMoved(b[3], a[3], 0, out, "exactIn: pool token1");

        assertEq(token0.balanceOf(address(lobster)), 0, "proxy kept token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy kept token1");
    }

    // ---------------------------------------------------------------------------
    // No unchecked entry point
    // ---------------------------------------------------------------------------

    /// @notice Every fund-moving entry point is a checked one: an unregistered caller is refused by all
    /// six swap and mint entry points (mint, exactInputSingle, exactOutputSingle, exactInputSingleV4,
    /// exactOutputSingleV4, batchSwap with each of the four item types) and by modifyLiquidityV4,
    /// before anything runs, and plain ETH is refused. (Callbacks: see the next test.)
    function test_noUncheckedEntryPoints() public {
        PoolKey memory v4Pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        V4ExactInputSingleParams memory v4In = V4ExactInputSingleParams({
            poolKey: v4Pool,
            zeroForOne: true,
            recipient: vaultB,
            deadline: block.timestamp,
            amountIn: 1e18,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        V4ExactOutputSingleParams memory v4Out = V4ExactOutputSingleParams({
            poolKey: v4Pool,
            zeroForOne: true,
            recipient: vaultB,
            deadline: block.timestamp,
            amountOut: 1e18,
            amountInMaximum: type(uint128).max,
            sqrtPriceLimitX96: 0
        });
        bytes[][4] memory batches;
        for (uint256 i = 0; i < 4; i++) {
            batches[i] = new bytes[](1);
        }
        batches[0][0] = abi.encodePacked(SwapType.V3_EXACT_INPUT, abi.encode(_exactIn(true, FEE, vaultB)));
        batches[1][0] = abi.encodePacked(SwapType.V3_EXACT_OUTPUT, abi.encode(_exactOut(true, FEE, vaultB, 1e18)));
        batches[2][0] = abi.encodePacked(SwapType.V4_EXACT_INPUT, abi.encode(v4In));
        batches[3][0] = abi.encodePacked(SwapType.V4_EXACT_OUTPUT, abi.encode(v4Out));

        bytes[3] memory v3 = _calls(FEE, vaultB);
        bytes[9] memory entryPoints = [
            v3[0], // mint
            v3[1], // exactInputSingle
            v3[2], // exactOutputSingle
            abi.encodeCall(LobsterProxy.exactInputSingleV4, (v4In)),
            abi.encodeCall(LobsterProxy.exactOutputSingleV4, (v4Out)),
            abi.encodeCall(LobsterProxy.batchSwap, (batches[0])),
            abi.encodeCall(LobsterProxy.batchSwap, (batches[1])),
            abi.encodeCall(LobsterProxy.batchSwap, (batches[2])),
            abi.encodeCall(LobsterProxy.batchSwap, (batches[3]))
        ];
        for (uint256 i = 0; i < entryPoints.length; i++) {
            vm.prank(vaultB);
            (bool ok, bytes memory ret) = address(lobster).call(entryPoints[i]);
            assertFalse(ok, string.concat("unchecked entry point ", vm.toString(i)));
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PoolNotAllowed.selector), vm.toString(i));
        }

        // V4 liquidity: refused before anything runs for a vault that has not configured its Roles
        // modifier (adds additionally need MINT on the pool, exits do not; see LobsterV4Liquidity.t.sol)
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        lobster.modifyLiquidityV4(new V4LiquidityOp[](0), block.timestamp);

        vm.deal(vaultA, 1e18);
        vm.prank(vaultA);
        (bool sent,) = address(lobster).call{value: 1e18}("");
        assertFalse(sent, "proxy accepted ETH");
    }

    // ---------------------------------------------------------------------------
    // Exact-output swaps
    // ---------------------------------------------------------------------------

    function test_exactOutputSingle_deliversExactlyAmountOut() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256[4] memory before = _balances(vaultA);

        vm.prank(vaultA);
        uint256 amountIn = lobster.exactOutputSingle(_exactOut(true, FEE, vaultA, 1e18));

        uint256[4] memory afterSwap = _balances(vaultA);
        assertEq(afterSwap[1], before[1] + 1e18, "vault did not receive exactly amountOut");
        assertEq(before[0] - afterSwap[0], amountIn, "vault paid a different amount than reported");
        assertGt(amountIn, 1e18, "no fee paid at a 1:1 price");
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy kept token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy kept token1");
    }

    function test_exactOutputSingle_amountInMaximumIsEnforced() public {
        _set(vaultA, _key(FEE), SWAP);
        ExactOutputSingleParams memory p = _exactOut(true, FEE, vaultA, 1e18);
        p.amountInMaximum = 1e18; // less than the 1e18 plus fee the swap really costs
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        lobster.exactOutputSingle(p);
    }

    /// @notice Without a price limit, an order the pool cannot fill in full reverts instead of
    /// spending `amountInMaximum` on a part of it
    function test_exactOutputSingle_partialFillReverts() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256[4] memory before = _balances(vaultA);

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        lobster.exactOutputSingle(_exactOut(true, FEE, vaultA, 5_000e18)); // the pool holds ~1,000

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "a refused swap moved funds");
        }
    }

    function test_mintOnlyPool_cannotBeSwappedExactOut() public {
        _set(vaultA, _key(FEE), MINT);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactOutputSingle(_exactOut(true, FEE, vaultA, 1e18));
    }

    function test_batch_exactOutputLegIsChecked() public {
        bytes[] memory batch = new bytes[](1);
        batch[0] = abi.encodePacked(SwapType.V3_EXACT_OUTPUT, abi.encode(_exactOut(true, FEE, vaultA, 1e18)));

        // unregistered pool
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.batchSwap(batch);

        // registered, but paying out to someone else
        _set(vaultA, _key(FEE), SWAP);
        batch[0] = abi.encodePacked(SwapType.V3_EXACT_OUTPUT, abi.encode(_exactOut(true, FEE, vaultB, 1e18)));
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        lobster.batchSwap(batch);

        // registered and to the vault: runs, and returns the amount paid
        batch[0] = abi.encodePacked(SwapType.V3_EXACT_OUTPUT, abi.encode(_exactOut(true, FEE, vaultA, 1e18)));
        uint256 before = token1.balanceOf(vaultA);
        vm.prank(vaultA);
        uint256[] memory amounts = lobster.batchSwap(batch);
        assertEq(token1.balanceOf(vaultA), before + 1e18, "vault did not receive exactly amountOut");
        assertGt(amounts[0], 1e18, "batch did not report the amount paid");
    }

    /// @notice The callbacks spend a payer's funds but only a genuine pool can call them; naming a
    /// vault as payer from anywhere else fails
    function test_callbacksCannotBeForged() public {
        uint256[4] memory before = _balances(vaultA);
        vm.startPrank(makeAddr("attacker"));
        vm.expectRevert();
        lobster.uniswapV3SwapCallback(
            1e18,
            0,
            abi.encode(SwapCallbackData({tokenIn: address(token0), tokenOut: address(token1), fee: FEE, payer: vaultA}))
        );
        vm.expectRevert();
        lobster.uniswapV3MintCallback(
            1e18,
            1e18,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.getPoolKey(address(token0), address(token1), FEE), payer: vaultA
                })
            )
        );
        vm.stopPrank();
        uint256[4] memory afterwards = _balances(vaultA);
        for (uint256 k = 0; k < 4; k++) {
            assertEq(afterwards[k], before[k], "a forged callback moved funds");
        }
    }

    // ---------------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------------

    /// @notice `setPools` is covered by the reentrancy lock: a token delivered mid-swap cannot call it
    function test_setPools_isCoveredByTheReentrancyLock() public {
        SetPoolsOnTransfer evil = new SetPoolsOnTransfer();
        evil.mint(address(this), 100_000e18);
        evil.approve(address(lobster), type(uint256).max);
        _createPoolWithLiquidity(address(token0), address(evil), FEE);
        address evilPool =
            PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(address(token0), address(evil), FEE));
        _set(vaultA, lobster.v3Key(evilPool), SWAP);
        _anyPrice(vaultA, lobster.v3Key(evilPool));
        evil.arm(address(lobster), vaultA); // fires when the pool delivers EVIL to the vault

        vm.prank(vaultA);
        lobster.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(evil),
                fee: FEE,
                recipient: vaultA,
                deadline: block.timestamp,
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(evil.balanceOf(vaultA), 0, "the swap did not deliver; test proves nothing");
        assertFalse(evil.attackSucceeded(), "setPools ran during a swap");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "setPools failed for an unexpected reason"
        );
    }

    // ---------------------------------------------------------------------------
    // Price bands
    // ---------------------------------------------------------------------------

    function _tick(uint24 fee) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3PoolMinimal(_pool(fee)).slot0();
    }

    function _band(address vault, int24 minTick, int24 maxTick) internal {
        bytes32 key = _key(FEE);
        vm.prank(vault);
        lobster.setPriceBand(key, minTick, maxTick);
    }

    function test_priceBand_setEmitsAndReads() public {
        bytes32 key = _key(FEE);
        vm.expectEmit(true, true, false, true, address(lobster));
        emit PoolRegistry.PriceBandSet(vaultA, key, -1200, 800);
        _band(vaultA, -1200, 800);

        (int24 minTick, int24 maxTick) = lobster.priceBandOf(vaultA, key);
        assertEq(minTick, -1200);
        assertEq(maxTick, 800);
    }

    function test_priceBand_invalidBandsRevert() public {
        bytes32 key = _key(FEE);
        int24[2][4] memory bad = [
            [int24(100), int24(100)], // empty
            [int24(100), int24(-100)], // inverted
            [TickMath.MIN_TICK - 1, int24(0)], // below Uniswap's range
            [int24(0), TickMath.MAX_TICK + 1] // above it
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(vaultA);
            vm.expectRevert(IProxyErrors.InvalidPriceBand.selector);
            lobster.setPriceBand(key, bad[i][0], bad[i][1]);
        }
    }

    function test_priceBand_isPerVaultAndPerPool() public {
        _band(vaultA, -10, 10);

        (int24 minTick, int24 maxTick) = lobster.priceBandOf(vaultA, _key(FEE));
        assertEq(minTick, -10);
        assertEq(maxTick, 10);
        // vault B's band on the same pool, and vault A's on another pool, are untouched
        (minTick, maxTick) = lobster.priceBandOf(vaultB, _key(FEE));
        assertEq(minTick, TickMath.MIN_TICK);
        assertEq(maxTick, TickMath.MAX_TICK);
        (minTick, maxTick) = lobster.priceBandOf(vaultA, _key(OTHER_FEE));
        assertEq(minTick, TickMath.MIN_TICK);
        assertEq(maxTick, TickMath.MAX_TICK);
    }

    function test_mint_withoutPriceBand_reverts() public {
        _set(vaultA, _key(FEE), MINT);
        _band(vaultA, 0, 0); // cleared, as if never set

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    function test_mint_registryIsCheckedBeforeTheBand() public {
        _band(vaultA, 0, 0);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    function test_mint_outsideBand_reverts() public {
        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);

        _band(vaultA, tick + 1, tick + 100); // price just below the band
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, tick - 100, tick - 1); // price just above the band
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    function test_mint_bandEdgesAreInclusive() public {
        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);

        _band(vaultA, tick, tick + 1);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, tick - 1, tick);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    /// @notice The scenario bands exist for: the price is pushed away, the vault's mint is refused, and
    /// it goes through again once the vault's owners move the band
    function test_mint_afterPriceMove_refusedUntilBandMoved() public {
        _set(vaultA, _key(FEE), BOTH);
        int24 start = _tick(FEE);
        _band(vaultA, start - 100, start + 100);

        // someone else's large swap moves the pool well past vault A's band (vault B allows any price)
        _set(vaultB, _key(FEE), SWAP);
        ExactInputSingleParams memory push = _exactIn(true, FEE, vaultB);
        push.amountIn = 200e18;
        vm.prank(vaultB);
        lobster.exactInputSingle(push);
        int24 moved = _tick(FEE);
        assertLt(moved, start - 100, "swap did not leave the band");

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, moved - 100, moved + 100);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    // --- swaps -----------------------------------------------------------------

    function test_swap_withoutPriceBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        _band(vaultA, 0, 0);
        bytes[3] memory c = _calls(FEE, vaultA);
        // c[1] = exactInputSingle, c[2] = exactOutputSingle
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(vaultA);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, "swapped without a band");
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PriceBandNotSet.selector));
        }
    }

    function test_swap_registryIsCheckedBeforeTheBand() public {
        _band(vaultA, 0, 0);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
    }

    /// @notice The price is already outside the band when the swap starts
    function test_swap_startingOutsideBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick + 1, tick + 1000);
        bytes[3] memory c = _calls(FEE, vaultA);
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(vaultA);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, "swapped outside the band");
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PriceOutOfBand.selector));
        }
    }

    /// @notice The swap itself would push the price out of the band: refused, nothing moves
    function test_swap_endingOutsideBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);
        uint256[4] memory before = _balances(vaultA);

        ExactInputSingleParams memory big = _exactIn(true, FEE, vaultA);
        big.amountIn = 200e18; // moves the price far below tick - 100
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.exactInputSingle(big);

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.exactOutputSingle(_exactOut(true, FEE, vaultA, 150e18));

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "a refused swap moved funds");
        }
    }

    function test_swap_insideBand_succeeds() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        vm.startPrank(vaultA);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA)); // 1e18: a few ticks at most
        lobster.exactOutputSingle(_exactOut(false, FEE, vaultA, 1e18));
        vm.stopPrank();
        assertGe(_tick(FEE), tick - 100);
        assertLe(_tick(FEE), tick + 100);
    }

    /// @notice A sandwich: the attacker pushes the price out of the vault's band first. The vault's
    /// swap is refused instead of trading at the manipulated price.
    function test_swap_afterManipulation_isRefused() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        // the attacker (vault B, any price allowed) front-runs
        _set(vaultB, _key(FEE), SWAP);
        ExactInputSingleParams memory front = _exactIn(true, FEE, vaultB);
        front.amountIn = 200e18;
        vm.prank(vaultB);
        lobster.exactInputSingle(front);

        // the victim's swap, with no slippage protection of its own, is refused
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.exactInputSingle(_exactIn(true, FEE, vaultA));
    }

    function test_batch_legsAreBandChecked() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        ExactInputSingleParams memory big = _exactIn(true, FEE, vaultA);
        big.amountIn = 200e18;
        bytes[] memory batch = new bytes[](2);
        batch[0] = abi.encodePacked(SwapType.V3_EXACT_INPUT, abi.encode(_exactIn(true, FEE, vaultA)));
        batch[1] = abi.encodePacked(SwapType.V3_EXACT_INPUT, abi.encode(big));
        uint256[4] memory before = _balances(vaultA);

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.batchSwap(batch);

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "the batch's first leg was not undone");
        }
    }
}
