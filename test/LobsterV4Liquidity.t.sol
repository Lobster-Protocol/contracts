// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {LobsterProxy} from "../src/LobsterProxy.sol";
import {UniswapV4LiquidityProxy, V4LiquidityOp} from "../src/UniswapV4LiquidityProxy.sol";
import {Operation} from "../src/interfaces/zodiac/IRoles.sol";
import {V4ExactInputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IHooks as ProxyIHooks,
    IPoolManagerMinimal,
    ModifyLiquidityParams
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {MockSafe} from "./Mocks/zodiac/MockSafe.sol";
import {SwapType} from "../src/UniswapBatchSwapProxy.sol";
import {Chaining} from "../src/libraries/Chaining.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockRoles} from "./Mocks/zodiac/MockRoles.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice A token that, the first time it is pulled with `transferFrom`, calls `target` with `attack`
/// and records the outcome
contract ReenterOnTransferFrom is MockERC20 {
    address public target;
    bytes public attack;
    bool public armed;
    uint256 public attempts;
    bool public attackSucceeded;
    bytes public attackRevertData;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function arm(address _target, bytes calldata _attack) external {
        (target, attack, armed) = (_target, _attack, true);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            attempts++;
            (attackSucceeded, attackRevertData) = target.call(attack);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @notice LobsterProxy's V4 liquidity (modifyLiquidityV4) against a real V4 PoolManager, with a mock Safe and a mock Roles v2
/// modifier configured exactly as the backend is meant to configure the real ones:
/// - the executor's role allows `modifyLiquidityV4` on the proxy, with Send;
/// - the proxy's role allows `PoolManager.modifyLiquidity` behind the proxy's `check`, and
///   `PoolManager.take` with `to == avatar`; nothing else.
/// Unless a test needs a revert reason, operations go the production way: executor -> Roles -> Safe
/// -> proxy -> PoolManager.unlock -> proxy -> Roles -> Safe -> PoolManager.
contract LobsterV4LiquidityTest is BatchSwapFixture {
    bytes32 constant ROLE_PROXY = keccak256("LOBSTER_V4_LIQUIDITY");
    bytes32 constant ROLE_EXEC = keccak256("LOBSTER_EXECUTOR");
    int24 constant LOWER = -600;
    int24 constant UPPER = 600;
    address constant ETH = address(0);

    struct Vault {
        MockSafe safe;
        MockRoles roles;
        address executor;
    }

    LobsterProxy lobster;
    /// @dev The same contract as `lobster`, named for its liquidity role in these tests
    LobsterProxy liq;
    Vault a; // the vault most tests use
    address attacker = makeAddr("attacker");

    function setUp() public virtual override {
        super.setUp();
        lobster = new LobsterProxy(v3Factory, address(manager));
        liq = lobster;
        a = _newVault("A");
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev A funded vault, with its Roles modifier set up as in production and both V4 pools
    /// registered with MINT
    function _newVault(string memory name) internal returns (Vault memory v) {
        v.safe = new MockSafe();
        v.roles = new MockRoles(address(v.safe), address(v.safe));
        v.safe.enableModule(address(v.roles));

        // The proxy's role
        v.roles.enableModule(address(liq));
        v.roles.assignRole(address(liq), ROLE_PROXY, true);
        v.roles
            .scopeCustomCondition(
                ROLE_PROXY, address(manager), IPoolManagerMinimal.modifyLiquidity.selector, address(liq)
            );
        v.roles.scopeParamEqualToAvatar(ROLE_PROXY, address(manager), IPoolManagerMinimal.take.selector, 1);

        // The executor's role
        v.executor = makeAddr(string.concat(name, " executor"));
        v.roles.enableModule(v.executor);
        v.roles.assignRole(v.executor, ROLE_EXEC, true);
        v.roles.allowFunction(ROLE_EXEC, address(liq), UniswapV4LiquidityProxy.modifyLiquidityV4.selector, true);

        // Funds, approval, registry and trampoline config: the owners' setup batch
        address safe = address(v.safe);
        token0.mint(safe, 1000e18);
        token1.mint(safe, 1000e18);
        vm.deal(safe, 100 ether);
        vm.startPrank(safe);
        token0.approve(address(liq), type(uint256).max);
        token1.approve(address(liq), type(uint256).max);
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = lobster.v4Key(cleanKey);
        keys[1] = lobster.v4Key(nativeKey);
        uint8[] memory perms = new uint8[](2);
        perms[0] = MINT;
        perms[1] = MINT;
        lobster.setPools(keys, perms);
        // Any price allowed, so these tests exercise the liquidity logic; bands have their own tests
        lobster.setPriceBand(keys[0], TickMath.MIN_TICK, TickMath.MAX_TICK);
        lobster.setPriceBand(keys[1], TickMath.MIN_TICK, TickMath.MAX_TICK);
        liq.setV4Roles(address(v.roles), ROLE_PROXY);
        vm.stopPrank();
    }

    function _op(ProxyPoolKey memory key, int256 delta) internal pure returns (V4LiquidityOp memory) {
        return _op(key, LOWER, UPPER, delta);
    }

    function _op(
        ProxyPoolKey memory key,
        int24 lower,
        int24 upper,
        int256 delta
    )
        internal
        pure
        returns (V4LiquidityOp memory)
    {
        return V4LiquidityOp({
            key: key,
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: delta,
            salt: bytes32(0),
            amount0Limit: delta > 0 ? type(uint128).max : 0,
            amount1Limit: delta > 0 ? type(uint128).max : 0
        });
    }

    function _ops(V4LiquidityOp memory x) internal pure returns (V4LiquidityOp[] memory ops) {
        ops = new V4LiquidityOp[](1);
        ops[0] = x;
    }

    function _ops(V4LiquidityOp memory x, V4LiquidityOp memory y) internal pure returns (V4LiquidityOp[] memory ops) {
        ops = new V4LiquidityOp[](2);
        (ops[0], ops[1]) = (x, y);
    }

    function _call(V4LiquidityOp[] memory ops) internal view returns (bytes memory) {
        return abi.encodeCall(UniswapV4LiquidityProxy.modifyLiquidityV4, (ops, block.timestamp));
    }

    /// @dev The production path: the executor, through the vault's Roles modifier
    function _viaExecutor(
        Vault memory v,
        V4LiquidityOp[] memory ops,
        uint256 value
    )
        internal
        returns (int256[] memory amounts0, int256[] memory amounts1)
    {
        vm.prank(v.executor);
        (, bytes memory ret) =
            v.roles.execTransactionWithRoleReturnData(address(liq), value, _call(ops), Operation.Call, ROLE_EXEC, true);
        (amounts0, amounts1) = abi.decode(ret, (int256[], int256[]));
    }

    /// @dev The vault calling directly, so revert reasons from the proxy surface unmasked
    function _asVault(Vault memory v, V4LiquidityOp[] memory ops) internal {
        vm.prank(address(v.safe));
        liq.modifyLiquidityV4(ops, block.timestamp);
    }

    function _liquidity(
        address owner,
        ProxyPoolKey memory key,
        int24 lower,
        int24 upper
    )
        internal
        view
        returns (uint128 liquidity)
    {
        (liquidity,,) = StateLibrary.getPositionInfo(
            IPoolManager(address(manager)), PoolId.wrap(keccak256(abi.encode(key))), owner, lower, upper, bytes32(0)
        );
    }

    function _liquidity(address owner, ProxyPoolKey memory key) internal view returns (uint128) {
        return _liquidity(owner, key, LOWER, UPPER);
    }

    function _delta(address target, address currency) internal view returns (int256) {
        return TransientStateLibrary.currencyDelta(IPoolManager(address(manager)), target, Currency.wrap(currency));
    }

    /// @dev Nothing left behind: no balance in the proxy, no open delta for the vault or the proxy
    function _assertClean(Vault memory v) internal view {
        assertEq(token0.balanceOf(address(liq)), 0, "proxy holds token0");
        assertEq(token1.balanceOf(address(liq)), 0, "proxy holds token1");
        assertEq(address(liq).balance, 0, "proxy holds ETH");
        address[3] memory cs = [ETH, address(token0), address(token1)];
        for (uint256 i = 0; i < 3; i++) {
            assertEq(_delta(address(v.safe), cs[i]), 0, "vault delta open");
            assertEq(_delta(address(liq), cs[i]), 0, "proxy delta open");
            assertEq(_delta(address(v.roles), cs[i]), 0, "modifier delta open");
        }
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(IPoolManager(address(manager))), 0, "nonzero deltas");
        assertEq(_liquidity(address(liq), cleanKey), 0, "proxy owns a position");
        assertEq(_liquidity(address(liq), nativeKey), 0, "proxy owns a position");
    }

    function _bal(address who) internal view returns (uint256[3] memory b) {
        b = [who.balance, token0.balanceOf(who), token1.balanceOf(who)];
    }

    /// @dev `after - before == delta` for one balance
    function _assertMoved(uint256 before, uint256 afterwards, int256 delta, string memory what) internal pure {
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(int256(afterwards) - int256(before), delta, what); // test balances are far below 2**255
    }

    /// @dev Some swaps through the pool in both directions, so LPs earn fees
    function _generateFees(ProxyPoolKey memory key) internal {
        vm.startPrank(user);
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = i == 0;
            proxy.exactInputSingleV4{value: zeroForOne && ProxyCurrency.unwrap(key.currency0) == ETH ? 5e18 : 0}(
                V4ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    recipient: user,
                    deadline: block.timestamp,
                    amountIn: 5e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Add, remove, collect, exit, rebalance
    // ---------------------------------------------------------------------------

    function test_add_erc20_vaultOwnsThePosition() public {
        uint256[3] memory before = _bal(address(a.safe));
        (int256[] memory a0, int256[] memory a1) = _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);

        assertLt(a0[0], 0, "paid no token0");
        assertLt(a1[0], 0, "paid no token1");
        uint256[3] memory nowHeld = _bal(address(a.safe));
        _assertMoved(before[1], nowHeld[1], a0[0], "vault token0");
        _assertMoved(before[2], nowHeld[2], a1[0], "vault token1");
        assertEq(_liquidity(address(a.safe), cleanKey), 10e18, "the vault does not own the position");
        assertEq(_liquidity(address(a.roles), cleanKey), 0, "the modifier owns a position");
        _assertClean(a);
    }

    function test_add_native_paysFromValueAndRefundsTheRest() public {
        uint256[3] memory before = _bal(address(a.safe));
        (int256[] memory a0, int256[] memory a1) = _viaExecutor(a, _ops(_op(nativeKey, 10e18)), 50 ether);

        assertLt(a0[0], 0);
        uint256[3] memory nowHeld = _bal(address(a.safe));
        _assertMoved(before[0], nowHeld[0], a0[0], "vault ETH: change not refunded");
        _assertMoved(before[2], nowHeld[2], a1[0], "vault token1");
        assertEq(_liquidity(address(a.safe), nativeKey), 10e18);
        _assertClean(a);
    }

    function test_add_native_withoutEnoughETH_reverts() public {
        vm.deal(address(a.safe), 100 ether);
        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        liq.modifyLiquidityV4{value: 1 wei}(_ops(_op(nativeKey, 10e18)), block.timestamp);
    }

    function test_remove_erc20_and_native() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18), _op(nativeKey, 10e18)), 50 ether);
        uint256[3] memory before = _bal(address(a.safe));

        (int256[] memory a0, int256[] memory a1) = _viaExecutor(a, _ops(_op(cleanKey, -4e18), _op(nativeKey, -4e18)), 0);

        for (uint256 i = 0; i < 2; i++) {
            assertGt(a0[i], 0, "received no currency0");
            assertGt(a1[i], 0, "received no currency1");
        }
        uint256[3] memory nowHeld = _bal(address(a.safe));
        _assertMoved(before[0], nowHeld[0], a0[1], "vault ETH");
        _assertMoved(before[1], nowHeld[1], a0[0], "vault token0");
        _assertMoved(before[2], nowHeld[2], a1[0] + a1[1], "vault token1");
        assertEq(_liquidity(address(a.safe), cleanKey), 6e18);
        assertEq(_liquidity(address(a.safe), nativeKey), 6e18);
        _assertClean(a);
    }

    function test_collectFees_erc20_and_native() public {
        _viaExecutor(a, _ops(_op(cleanKey, 100e18), _op(nativeKey, 100e18)), 50 ether);
        _generateFees(cleanKey);
        _generateFees(nativeKey);
        uint256[3] memory before = _bal(address(a.safe));

        (int256[] memory a0, int256[] memory a1) = _viaExecutor(a, _ops(_op(cleanKey, 0), _op(nativeKey, 0)), 0);

        for (uint256 i = 0; i < 2; i++) {
            assertGt(a0[i], 0, "no currency0 fees");
            assertGt(a1[i], 0, "no currency1 fees");
        }
        uint256[3] memory nowHeld = _bal(address(a.safe));
        _assertMoved(before[0], nowHeld[0], a0[1], "vault ETH");
        _assertMoved(before[1], nowHeld[1], a0[0], "vault token0");
        _assertMoved(before[2], nowHeld[2], a1[0] + a1[1], "vault token1");
        assertEq(_liquidity(address(a.safe), cleanKey), 100e18, "collect changed liquidity");
        _assertClean(a);
    }

    function test_fullExit_returnsEverything() public {
        uint256[3] memory start = _bal(address(a.safe));
        _viaExecutor(a, _ops(_op(cleanKey, 10e18), _op(nativeKey, 10e18)), 50 ether);
        _viaExecutor(a, _ops(_op(cleanKey, -10e18), _op(nativeKey, -10e18)), 0);

        assertEq(_liquidity(address(a.safe), cleanKey), 0);
        assertEq(_liquidity(address(a.safe), nativeKey), 0);
        uint256[3] memory end = _bal(address(a.safe));
        for (uint256 i = 0; i < 3; i++) {
            // Uniswap rounds against the LP: at most a wei or two per leg
            assertApproxEqAbs(end[i], start[i], 2, "funds lost on a round trip");
            assertLe(end[i], start[i]);
        }
        _assertClean(a);
    }

    /// @notice Remove one range and add another in one call: settled once, on the net amounts
    function test_rebalance_removeAndAdd_settlesTheNet() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18), _op(nativeKey, 10e18)), 50 ether);
        uint256[3] memory before = _bal(address(a.safe));

        V4LiquidityOp[] memory ops = new V4LiquidityOp[](4);
        ops[0] = _op(cleanKey, -10e18);
        ops[1] = _op(cleanKey, -1200, 1200, 5e18);
        ops[2] = _op(nativeKey, -10e18);
        ops[3] = _op(nativeKey, -1200, 1200, 5e18);
        (int256[] memory a0, int256[] memory a1) = _viaExecutor(a, ops, 50 ether);

        uint256[3] memory nowHeld = _bal(address(a.safe));
        _assertMoved(before[0], nowHeld[0], a0[2] + a0[3], "vault ETH");
        _assertMoved(before[1], nowHeld[1], a0[0] + a0[1], "vault token0");
        _assertMoved(before[2], nowHeld[2], a1[0] + a1[1] + a1[2] + a1[3], "vault token1");
        assertEq(_liquidity(address(a.safe), cleanKey), 0, "old range not removed");
        assertEq(_liquidity(address(a.safe), cleanKey, -1200, 1200), 5e18, "new range not added");
        assertEq(_liquidity(address(a.safe), nativeKey, -1200, 1200), 5e18, "new range not added");
        _assertClean(a);
    }

    /// @notice Only the net moves: a rebalance pulls no more tokens than the net owed
    function test_rebalance_pullsOnlyTheNet() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        // Same range, remove 10 and add 10 back: nets to (almost) nothing, so (almost) nothing moves
        uint256[3] memory before = _bal(address(a.safe));
        _viaExecutor(a, _ops(_op(cleanKey, -10e18), _op(cleanKey, 10e18)), 0);
        uint256[3] memory nowHeld = _bal(address(a.safe));
        assertApproxEqAbs(nowHeld[1], before[1], 2, "token0 moved");
        assertApproxEqAbs(nowHeld[2], before[2], 2, "token1 moved");
        assertEq(_liquidity(address(a.safe), cleanKey), 10e18);
        _assertClean(a);
    }

    // ---------------------------------------------------------------------------
    // Registry: adds need MINT, exits never depend on it
    // ---------------------------------------------------------------------------

    function _deregister(Vault memory v, ProxyPoolKey memory key) internal {
        bytes32[] memory k = new bytes32[](1);
        k[0] = lobster.v4Key(key);
        uint8[] memory p = new uint8[](1);
        vm.prank(address(v.safe));
        lobster.setPools(k, p);
    }

    function test_unregisteredPool_cannotBeAdded() public {
        _deregister(a, cleanKey);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        _asVault(a, _ops(_op(cleanKey, 1e18)));

        // SWAP alone is not MINT
        bytes32[] memory k = new bytes32[](1);
        k[0] = lobster.v4Key(cleanKey);
        uint8[] memory p = new uint8[](1);
        p[0] = SWAP;
        vm.prank(address(a.safe));
        lobster.setPools(k, p);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        _asVault(a, _ops(_op(cleanKey, 1e18)));
    }

    function test_deregisteredPool_canStillBeExited() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18), _op(nativeKey, 10e18)), 50 ether);
        _generateFees(cleanKey);
        _deregister(a, cleanKey);
        _deregister(a, nativeKey);

        (int256[] memory f0,) = _viaExecutor(a, _ops(_op(cleanKey, 0)), 0); // collect
        assertGt(f0[0], 0);
        _viaExecutor(a, _ops(_op(cleanKey, -10e18), _op(nativeKey, -10e18)), 0); // exit
        assertEq(_liquidity(address(a.safe), cleanKey), 0);
        assertEq(_liquidity(address(a.safe), nativeKey), 0);
        _assertClean(a);
    }

    /// @notice Even if the proxy's own pre-check were skipped, the Roles condition refuses an add on
    /// an unregistered pool
    function test_rolesConditionAlsoRefusesUnregisteredAdds() public {
        _deregister(a, cleanKey);
        bytes memory call = abi.encodeCall(
            IPoolManagerMinimal.modifyLiquidity,
            (cleanKey, ModifyLiquidityParams({tickLower: LOWER, tickUpper: UPPER, liquidityDelta: 1e18, salt: 0}), "")
        );
        vm.prank(address(liq));
        bytes32 reason = "Pool not allowed";
        vm.expectRevert(abi.encodeWithSelector(MockRoles.ConditionViolation.selector, reason));
        a.roles.execTransactionWithRole(address(manager), 0, call, Operation.Call, ROLE_PROXY, true);
    }

    // ---------------------------------------------------------------------------
    // Who can act on whose positions
    // ---------------------------------------------------------------------------

    function test_vaultCannotUseAnotherVaultsModifier() public {
        Vault memory b = _newVault("B");
        vm.prank(address(b.safe));
        vm.expectRevert(IProxyErrors.RolesModifierNotTheVaults.selector);
        liq.setV4Roles(address(a.roles), ROLE_PROXY);
        (address configured,) = liq.v4RolesOf(address(b.safe));
        assertEq(configured, address(b.roles), "B's config changed");
    }

    function test_executorCannotReachAnotherVault() public {
        Vault memory b = _newVault("B");
        _viaExecutor(b, _ops(_op(cleanKey, 10e18)), 0);
        uint256[3] memory bBefore = _bal(address(b.safe));

        // A's executor calling the proxy itself: it is not a vault, nothing is configured for it
        vm.prank(a.executor);
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -10e18)), block.timestamp);

        // A's executor on B's modifier: not a module there, let alone a member
        vm.prank(a.executor);
        vm.expectRevert(abi.encodeWithSelector(MockRoles.NotAuthorized.selector, a.executor));
        b.roles
            .execTransactionWithRoleReturnData(
                address(liq), 0, _call(_ops(_op(cleanKey, -10e18))), Operation.Call, ROLE_EXEC, true
            );

        // A's executor, through A's modifier: acts on A's (empty) position only, so B's is safe
        vm.prank(a.executor);
        vm.expectRevert(MockRoles.ModuleTransactionFailed.selector);
        a.roles
            .execTransactionWithRoleReturnData(
                address(liq), 0, _call(_ops(_op(cleanKey, -10e18))), Operation.Call, ROLE_EXEC, true
            );

        assertEq(_liquidity(address(b.safe), cleanKey), 10e18, "B's position moved");
        uint256[3] memory bAfter = _bal(address(b.safe));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bAfter[i], bBefore[i], "B's funds moved");
        }
    }

    /// @notice An attacker with a fully working setup of their own (their own Safe and modifier) can
    /// only ever touch their own positions and funds
    function test_attackerWithOwnSetup_cannotTouchTheVault() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        uint256[3] memory aBefore = _bal(address(a.safe));
        Vault memory x = _newVault("X");

        // Same pool, range and salt as A's position: X's own position, which is empty
        vm.prank(x.executor);
        vm.expectRevert(MockRoles.ModuleTransactionFailed.selector);
        x.roles
            .execTransactionWithRoleReturnData(
                address(liq), 0, _call(_ops(_op(cleanKey, -10e18))), Operation.Call, ROLE_EXEC, true
            );

        assertEq(_liquidity(address(a.safe), cleanKey), 10e18);
        uint256[3] memory aAfter = _bal(address(a.safe));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(aAfter[i], aBefore[i], "A's funds moved");
        }
    }

    function test_rolesConfig_unsetOrMismatched_reverts() public {
        MockSafe c = new MockSafe();
        MockRoles cRoles = new MockRoles(address(c), address(c));

        vm.prank(address(c));
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -1)), block.timestamp);

        // a modifier whose avatar and target differ is refused
        cRoles.setTarget(attacker);
        vm.prank(address(c));
        vm.expectRevert(IProxyErrors.RolesModifierNotTheVaults.selector);
        liq.setV4Roles(address(cRoles), ROLE_PROXY);
        cRoles.setTarget(address(c));

        vm.prank(address(c));
        vm.expectEmit(address(liq));
        emit UniswapV4LiquidityProxy.V4RolesSet(address(c), address(cRoles), ROLE_PROXY);
        liq.setV4Roles(address(cRoles), ROLE_PROXY);

        // The modifier is re-checked on every call: re-pointed after configuration, it is refused
        cRoles.setAvatar(attacker);
        vm.prank(address(c));
        vm.expectRevert(IProxyErrors.RolesModifierNotTheVaults.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -1)), block.timestamp);
        cRoles.setAvatar(address(c));
        cRoles.setTarget(attacker);
        vm.prank(address(c));
        vm.expectRevert(IProxyErrors.RolesModifierNotTheVaults.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -1)), block.timestamp);

        // Cleared
        vm.prank(address(c));
        liq.setV4Roles(address(0), bytes32(0));
        vm.prank(address(c));
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -1)), block.timestamp);
    }

    /// @notice The proxy's role allows nothing beyond the two PoolManager calls, and `take` only to the
    /// vault: the mock enforces the intended Roles config
    function test_proxyRole_isLimitedToModifyAndTakeToTheVault() public {
        token0.mint(address(manager), 1e18);
        vm.startPrank(address(liq));
        bytes32 reason = "ParameterNotAllowed";
        vm.expectRevert(abi.encodeWithSelector(MockRoles.ConditionViolation.selector, reason));
        a.roles
            .execTransactionWithRole(
                address(manager),
                0,
                abi.encodeCall(IPoolManagerMinimal.take, (ProxyCurrency.wrap(address(token0)), attacker, 1)),
                Operation.Call,
                ROLE_PROXY,
                true
            );
        vm.expectRevert(MockRoles.FunctionNotAllowed.selector);
        a.roles
            .execTransactionWithRole(
                address(token0), 0, abi.encodeCall(token0.transfer, (attacker, 1)), Operation.Call, ROLE_PROXY, true
            );
        vm.expectRevert(MockRoles.FunctionNotAllowed.selector);
        a.roles
            .execTransactionWithRole(
                address(manager),
                0,
                abi.encodeCall(IPoolManagerMinimal.settleFor, (attacker)),
                Operation.Call,
                ROLE_PROXY,
                true
            );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Pools, limits, deadline, callback
    // ---------------------------------------------------------------------------

    function test_hookedPool_isRejected() public {
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        bytes32[] memory k = new bytes32[](1);
        k[0] = lobster.v4Key(hooked);
        uint8[] memory p = new uint8[](1);
        p[0] = MINT;
        vm.prank(address(a.safe));
        lobster.setPools(k, p);

        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        _asVault(a, _ops(_op(hooked, 1e18)));
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        _asVault(a, _ops(_op(cleanKey, 1e18), _op(hooked, -1e18)));
    }

    function test_slippageLimits() public {
        V4LiquidityOp memory add = _op(cleanKey, 10e18);
        add.amount0Limit = 1e17; // 10e18 of liquidity over +-600 ticks needs ~0.3e18 of each token
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        _asVault(a, _ops(add));
        add = _op(cleanKey, 10e18);
        add.amount1Limit = 1e17;
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        _asVault(a, _ops(add));

        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        V4LiquidityOp memory remove = _op(cleanKey, -10e18);
        remove.amount0Limit = 1e18;
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        _asVault(a, _ops(remove));
        remove = _op(cleanKey, -10e18);
        remove.amount1Limit = 1e18;
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        _asVault(a, _ops(remove));

        V4LiquidityOp memory collect = _op(cleanKey, 0);
        collect.amount0Limit = 1; // no fees yet
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        _asVault(a, _ops(collect));

        // Exactly at the limits passes
        (int256[] memory r0, int256[] memory r1) = _quoteThenRevert(_ops(_op(cleanKey, -10e18)));
        remove = _op(cleanKey, -10e18);
        // forge-lint: disable-next-line(unsafe-typecast)
        (remove.amount0Limit, remove.amount1Limit) = (uint128(uint256(r0[0])), uint128(uint256(r1[0])));
        _asVault(a, _ops(remove));
        _assertClean(a);
    }

    function _quoteThenRevert(V4LiquidityOp[] memory ops) internal returns (int256[] memory a0, int256[] memory a1) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(a.safe));
        (a0, a1) = liq.modifyLiquidityV4(ops, block.timestamp);
        vm.revertToState(snap);
    }

    function test_deadline() public {
        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        vm.warp(block.timestamp + 1);
        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -10e18)), block.timestamp - 1);

        // An exit only needs a deadline of now, and no registration
        _deregister(a, cleanKey);
        vm.prank(address(a.safe));
        liq.modifyLiquidityV4(_ops(_op(cleanKey, -10e18)), block.timestamp);
        assertEq(_liquidity(address(a.safe), cleanKey), 0);
    }

    function test_forgedCallback_reverts() public {
        // Correctly tagged as a liquidity unlock (0x02), so only the missing context can stop it
        bytes memory data = bytes.concat(bytes1(0x02), abi.encode(_ops(_op(cleanKey, -10e18))));
        vm.prank(attacker);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        liq.unlockCallback(data);

        // From the PoolManager, but not inside a modifyLiquidityV4
        vm.prank(address(manager));
        vm.expectRevert(IProxyErrors.NoLiquidityOperation.selector);
        liq.unlockCallback(data);

        // Nor after one: the context is cleared when it ends (same transaction, so transient storage
        // would otherwise still hold it)
        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        vm.prank(address(manager));
        vm.expectRevert(IProxyErrors.NoLiquidityOperation.selector);
        liq.unlockCallback(data);
    }

    function test_proxyAcceptsNoETH() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool ok,) = address(liq).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /// @notice Liquidity and swaps share one contract, so while an operation runs the proxy holds the
    /// vault's msg.value. A token pulled mid-operation tries to spend it with a HELD_BALANCE batch leg
    /// (the ETH would go to the token's own swap). The reentrancy lock refuses it, and the vault pays
    /// exactly what its position cost. (Without the lock this particular leg would still fail, with the
    /// PoolManager's AlreadyUnlocked, a second layer; the test pins the first.)
    function test_reentryDuringALiquidityOperation_cannotSpendTheVaultsEth() public {
        ReenterOnTransferFrom evil = new ReenterOnTransferFrom();
        evil.mint(address(this), 1000e18);
        evil.approve(address(lpRouter), type(uint256).max);
        PoolKey memory k = _v4CoreKey(ETH, address(evil));
        manager.initialize(k, SQRT_PRICE_1_1);
        _addV4Liquidity(k, 1000e18);
        ProxyPoolKey memory evilKey = _toProxyKey(k);

        evil.mint(address(a.safe), 100e18);
        vm.prank(address(a.safe));
        evil.approve(address(liq), type(uint256).max);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lobster.v4Key(evilKey);
        uint8[] memory perms = new uint8[](1);
        perms[0] = MINT | SWAP;
        vm.prank(address(a.safe));
        lobster.setPools(keys, perms);
        vm.prank(address(a.safe));
        lobster.setPriceBand(keys[0], TickMath.MIN_TICK, TickMath.MAX_TICK);

        bytes[] memory steal = new bytes[](1);
        steal[0] = abi.encodePacked(
            SwapType.V4_EXACT_INPUT,
            abi.encode(
                V4ExactInputSingleParams({
                    poolKey: evilKey,
                    zeroForOne: true, // ETH in: everything the proxy holds
                    recipient: address(evil),
                    deadline: block.timestamp,
                    amountIn: uint128(Chaining.HELD_BALANCE),
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        // The token is a caller in its own right, with the pool registered: only the lock can stop it
        perms[0] = SWAP;
        vm.prank(address(evil));
        lobster.setPools(keys, perms);
        evil.arm(address(liq), abi.encodeCall(lobster.batchSwap, (steal)));

        uint256 ethBefore = address(a.safe).balance;
        (int256[] memory a0,) = _viaExecutor(a, _ops(_op(evilKey, 10e18)), 50 ether);

        assertEq(evil.attempts(), 1, "the token never re-entered; test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entrant batch succeeded");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entrant batch failed for an unexpected reason"
        );
        _assertMoved(ethBefore, address(a.safe).balance, a0[0], "vault paid more ETH than its position cost");
        assertEq(address(liq).balance, 0, "proxy kept ETH");
    }

    // ---------------------------------------------------------------------------
    // The Roles custom condition
    // ---------------------------------------------------------------------------

    function _modifyCalldata(ProxyPoolKey memory key, int256 delta) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IPoolManagerMinimal.modifyLiquidity,
            (key, ModifyLiquidityParams({tickLower: LOWER, tickUpper: UPPER, liquidityDelta: delta, salt: 0}), "")
        );
    }

    function _check(address to, uint256 value, bytes memory data, uint8 op) internal returns (bool ok, bytes32 why) {
        vm.prank(address(a.roles));
        return liq.check(to, value, data, op, 4, data.length - 4, bytes12(0));
    }

    function _assertVerdict(bool ok, bytes32 why, bool expectedOk, bytes32 expectedWhy) internal pure {
        assertEq(ok, expectedOk, "verdict");
        assertEq(why, expectedWhy, "reason");
    }

    function test_check_verdicts() public {
        address pm = address(manager);
        (bool ok, bytes32 why) = _check(pm, 0, _modifyCalldata(cleanKey, 1e18), 0);
        _assertVerdict(ok, why, true, 0);
        (ok, why) = _check(pm, 0, _modifyCalldata(cleanKey, -1e18), 0);
        _assertVerdict(ok, why, true, 0);
        (ok, why) = _check(pm, 0, _modifyCalldata(cleanKey, 0), 0);
        _assertVerdict(ok, why, true, 0);

        _deregister(a, cleanKey);
        (ok, why) = _check(pm, 0, _modifyCalldata(cleanKey, 1e18), 0);
        _assertVerdict(ok, why, false, "Pool not allowed");
        (ok, why) = _check(pm, 0, _modifyCalldata(cleanKey, -1e18), 0);
        _assertVerdict(ok, why, true, 0); // exits never depend on the registry

        bytes memory good = _modifyCalldata(nativeKey, 1e18);
        (ok, why) = _check(attacker, 0, good, 0);
        _assertVerdict(ok, why, false, "Not the PoolManager");
        (ok, why) = _check(pm, 1, good, 0);
        _assertVerdict(ok, why, false, "Value not allowed");
        (ok, why) = _check(pm, 0, good, 1);
        _assertVerdict(ok, why, false, "Not a call");

        bytes memory withHookData = abi.encodeCall(
            IPoolManagerMinimal.modifyLiquidity,
            (
                nativeKey,
                ModifyLiquidityParams({tickLower: LOWER, tickUpper: UPPER, liquidityDelta: 1, salt: 0}),
                hex"01"
            )
        );
        (ok, why) = _check(pm, 0, withHookData, 0);
        _assertVerdict(ok, why, false, "Malformed calldata");
        bytes memory fakeEmptyHookData = bytes.concat(good);
        fakeEmptyHookData[fakeEmptyHookData.length - 1] = 0x01; // hookData length 1, but no bytes
        (ok, why) = _check(pm, 0, fakeEmptyHookData, 0);
        _assertVerdict(ok, why, false, "Hook data not empty");

        ProxyPoolKey memory hooked = nativeKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        (ok, why) = _check(pm, 0, _modifyCalldata(hooked, -1), 0);
        _assertVerdict(ok, why, false, "Hooks not supported");

        bytes memory wrongSelector = bytes.concat(good);
        wrongSelector[0] = 0xff;
        (ok, why) = _check(pm, 0, wrongSelector, 0);
        _assertVerdict(ok, why, false, "Not modifyLiquidity");

        bytes memory dirty = bytes.concat(good);
        dirty[4] = 0x01; // currency0 with upper bits set
        (ok, why) = _check(pm, 0, dirty, 0);
        _assertVerdict(ok, why, false, "Malformed calldata");

        // Called by something that is not a modifier: adds have no vault to check against
        (ok, why) = liq.check(pm, 0, good, 0, 0, 0, bytes12(0));
        _assertVerdict(ok, why, false, "No avatar");
        (ok, why) = liq.check(pm, 0, _modifyCalldata(nativeKey, -1), 0, 0, 0, bytes12(0));
        _assertVerdict(ok, why, true, 0);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_check_neverReverts(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        uint8 op,
        uint256 location,
        uint256 size,
        bytes12 extra
    )
        public
    {
        vm.assume(caller != address(this));
        vm.prank(caller);
        liq.check(to, value, data, op, location, size, extra); // must not revert
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_check_corruptedCalldata_neverReverts(uint256 position, uint8 newByte, bool viaModifier) public {
        bytes memory data = _modifyCalldata(cleanKey, 1e18);
        data[bound(position, 0, data.length - 1)] = bytes1(newByte);
        if (viaModifier) vm.prank(address(a.roles));
        (bool ok,) = liq.check(address(manager), 0, data, 0, 0, 0, bytes12(0));
        // Whatever the byte, an allowed call still decodes to a hookless, registered add or an exit
        if (ok) {
            (ProxyPoolKey memory key, ModifyLiquidityParams memory params,) =
                abi.decode(_tail(data), (ProxyPoolKey, ModifyLiquidityParams, bytes));
            assertEq(address(key.hooks), address(0));
            if (params.liquidityDelta > 0) {
                assertEq(lobster.permissionsOf(address(a.safe), lobster.v4Key(key)) & MINT, MINT);
            }
        }
    }

    function _tail(bytes memory data) internal pure returns (bytes memory t) {
        t = new bytes(data.length - 4);
        for (uint256 i = 0; i < t.length; i++) {
            t[i] = data[i + 4];
        }
    }

    // ---------------------------------------------------------------------------
    // Random sequences: nothing is ever left behind
    // ---------------------------------------------------------------------------

    /// @notice Random adds, removes and collects on both pools, with random ETH: whether a call
    /// succeeds or reverts, the proxy holds nothing, no delta stays open, and the vault's positions
    /// are exactly what the successful calls made them
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_randomOperations_leaveNothingBehind(uint256 seed) public {
        uint128[2] memory ghost; // the vault's liquidity in cleanKey, nativeKey
        for (uint256 round = 0; round < 4; round++) {
            uint256 r = uint256(keccak256(abi.encode(seed, round)));
            uint256 n = 1 + r % 3;
            V4LiquidityOp[] memory ops = new V4LiquidityOp[](n);
            uint128[2] memory next = [ghost[0], ghost[1]]; // a copy, not an alias
            for (uint256 i = 0; i < n; i++) {
                uint256 ri = uint256(keccak256(abi.encode(r, i)));
                uint256 pool = ri % 2;
                ProxyPoolKey memory key = pool == 0 ? cleanKey : nativeKey;
                uint256 kind = (ri >> 8) % 3; // 0 add, 1 remove, 2 collect
                if (next[pool] == 0) kind = 0;
                int256 delta;
                if (kind == 0) {
                    delta = int256(bound(ri >> 16, 1e9, 20e18));
                    // forge-lint: disable-next-line(unsafe-typecast)
                    next[pool] += uint128(uint256(delta)); // bounded to 20e18 just above
                } else if (kind == 1) {
                    uint256 amount = bound(ri >> 16, 1, next[pool]);
                    // forge-lint: disable-next-line(unsafe-typecast)
                    delta = -int256(amount); // at most the position's liquidity, a uint128
                    // forge-lint: disable-next-line(unsafe-typecast)
                    next[pool] -= uint128(amount);
                }
                ops[i] = _op(key, delta);
            }
            uint256 value = (r >> 128) % 2 == 0 ? 0 : bound(r >> 64, 0, 30 ether);
            vm.deal(address(a.safe), 100 ether);

            vm.prank(a.executor);
            try a.roles
                .execTransactionWithRoleReturnData(address(liq), value, _call(ops), Operation.Call, ROLE_EXEC, true) {
                ghost = next;
            } catch {}

            _assertClean(a);
            assertEq(_liquidity(address(a.safe), cleanKey), ghost[0], "clean liquidity");
            assertEq(_liquidity(address(a.safe), nativeKey), ghost[1], "native liquidity");
        }
    }

    // ---------------------------------------------------------------------------
    // Price bands: adding needs the pool's live tick inside the vault's band; exiting never does
    // ---------------------------------------------------------------------------

    /// @dev The pool's current tick, read independently of the proxy with v4-core's StateLibrary
    function _v4Tick(ProxyPoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolId.wrap(keccak256(abi.encode(key))));
    }

    function _setBand(Vault memory v, ProxyPoolKey memory key, int24 minTick, int24 maxTick) internal {
        bytes32 k = lobster.v4Key(key);
        vm.prank(address(v.safe));
        lobster.setPriceBand(k, minTick, maxTick);
    }

    function test_add_withoutPriceBand_reverts() public {
        _setBand(a, cleanKey, 0, 0);
        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, 10e18)), block.timestamp);
    }

    function test_add_outsideBand_reverts() public {
        int24 tick = _v4Tick(cleanKey);

        _setBand(a, cleanKey, tick + 1, tick + 100);
        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, 10e18)), block.timestamp);

        _setBand(a, cleanKey, tick - 100, tick - 1);
        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, 10e18)), block.timestamp);
    }

    function test_add_bandEdgesAreInclusive() public {
        int24 tick = _v4Tick(cleanKey);

        _setBand(a, cleanKey, tick, tick + 1);
        _asVault(a, _ops(_op(cleanKey, 10e18)));
        _setBand(a, cleanKey, tick - 1, tick);
        _asVault(a, _ops(_op(cleanKey, 10e18)));

        assertEq(_liquidity(address(a.safe), cleanKey), 20e18, "both adds should have gone through");
    }

    /// @dev The production path, executor through Roles, is held to the same band
    function test_add_viaExecutor_respectsTheBand() public {
        int24 tick = _v4Tick(cleanKey);

        _setBand(a, cleanKey, tick + 1, tick + 100);
        vm.prank(a.executor);
        vm.expectRevert();
        a.roles
            .execTransactionWithRoleReturnData(
                address(liq), 0, _call(_ops(_op(cleanKey, 10e18))), Operation.Call, ROLE_EXEC, true
            );
        assertEq(_liquidity(address(a.safe), cleanKey), 0, "added outside the band");

        _setBand(a, cleanKey, tick - 100, tick + 100);
        _viaExecutor(a, _ops(_op(cleanKey, 10e18)), 0);
        assertEq(_liquidity(address(a.safe), cleanKey), 10e18, "add inside the band failed");
    }

    /// @notice A vault can always exit: removing and collecting do not look at the band
    function test_removeAndCollect_ignoreThePriceBand() public {
        _asVault(a, _ops(_op(cleanKey, 10e18)));

        _setBand(a, cleanKey, 0, 0);
        _asVault(a, _ops(_op(cleanKey, 0))); // collect only
        _asVault(a, _ops(_op(cleanKey, -10e18)));

        assertEq(_liquidity(address(a.safe), cleanKey), 0, "position not fully removed");
    }

    /// @notice The check reads the pool's live price: after a swap moves it out of the band, adding is
    /// refused until the vault's owners move the band
    function test_add_afterPriceMove_refusedUntilBandMoved() public {
        int24 start = _v4Tick(cleanKey);
        _setBand(a, cleanKey, start - 100, start + 100);

        vm.prank(user);
        proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: cleanKey,
                zeroForOne: true,
                recipient: user,
                deadline: block.timestamp,
                amountIn: 50e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        int24 moved = _v4Tick(cleanKey);
        assertLt(moved, start - 100, "swap did not leave the band");

        vm.prank(address(a.safe));
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        liq.modifyLiquidityV4(_ops(_op(cleanKey, 10e18)), block.timestamp);

        _setBand(a, cleanKey, moved - 100, moved + 100);
        _asVault(a, _ops(_op(cleanKey, 10e18)));
        assertEq(_liquidity(address(a.safe), cleanKey), 10e18, "add after moving the band failed");
    }
}
