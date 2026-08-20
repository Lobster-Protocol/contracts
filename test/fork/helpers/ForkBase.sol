// SPDX-License-Identifier: GPL-3.0
// Pinned to match src/UniswapProxy.sol so these tests exercise the same artifact the deploy script
// broadcasts. See the note at the top of UniswapProxy.sol.
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapProxy} from "../../../src/UniswapProxy.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";

/// @notice Shared fixture for the fork suites. See test/fork/README.md for how to run them.
/// @dev Two environment variables control what is under test:
/// - `FORK_RPC`  which chain to fork. Defaults to a local Anvil on 8545.
/// - `PROXY`     attach to an already-deployed instance instead of deploying a fresh one, i.e.
///               test what actually shipped rather than what is in src/.
///
/// Supports mainnet (or a fork of it) and Sepolia; addresses and trade sizes resolve per chain.
abstract contract ForkBase is Test {
    // --- Network addresses -----------------------------------------------------
    // Resolved per chain in `_loadNetwork`, not `constant`, so the same suite can run against a
    // mainnet fork and against Sepolia. `PoolAddress.POOL_INIT_CODE_HASH` is identical on both
    // (verified by deriving live pool addresses on each), so the v3 callback checks port unchanged.
    address internal V3_FACTORY;
    address internal POOL_MANAGER;

    address internal WETH;
    address internal USDC;
    address internal USDT;
    address internal DAI;

    // The "approver's real trading venue". Only meaningful where deep liquidity actually exists.
    address internal USDC_WETH_500;
    address internal USDC_WETH_3000;

    /// @notice The v4 ETH/USDC pool key components, per chain.
    uint24 internal V4_FEE;
    int24 internal V4_TICK_SPACING;

    /// @notice True only where the *token itself* is the canonical mainnet deployment.
    /// @dev Gates the handful of tests that are about a specific token's quirks (USDT returning no
    /// bool). Nothing to do with liquidity — see the trade sizes below for that.
    bool internal hasCanonicalTokens;

    // --- Chain-scaled trade sizes ----------------------------------------------
    // Sepolia's pools are real and usable but orders of magnitude thinner than mainnet's. The fix
    // is to size orders to the venue, not to skip the test: a swap that moves the price 1% proves
    // exactly as much about who pays as one that moves it 0.0001%.
    uint256 internal tradeUsdc; // a routine swap, in USDC units
    uint256 internal tradeWeth; // the same swap, in WETH units
    uint256 internal lpUsdc; // a position-sized amount of USDC
    uint256 internal lpWeth; // a position-sized amount of WETH
    uint256 internal fundUsdc; // starting wallet balance
    uint256 internal fundWeth; // starting wallet + ETH balance

    UniswapProxy internal proxy;
    IUniswapV3FactoryMinimal internal factory;

    address internal approver;
    address internal outsider;
    address internal recipient;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("FORK_RPC", string("http://127.0.0.1:8545")));
        _loadNetwork();
        factory = IUniswapV3FactoryMinimal(V3_FACTORY);

        // Assigned only after the fork is selected, because `_actor` has to see deployed code.
        approver = _actor("approver");
        outsider = _actor("outsider");
        recipient = _actor("recipient");

        address deployed = vm.envOr("PROXY", address(0));
        proxy = deployed == address(0) ? new UniswapProxy(V3_FACTORY, POOL_MANAGER) : UniswapProxy(deployed);

        // Sanity: attaching to a wrong/stale address would make every assertion below meaningless.
        require(address(proxy).code.length > 0, "no code at proxy");
        assertEq(proxy.UNI_V3_FACTORY(), V3_FACTORY, "proxy wired to wrong v3 factory");
        assertEq(address(proxy.POOL_MANAGER()), POOL_MANAGER, "proxy wired to wrong pool manager");

        // A freshly deployed proxy can land on an address that already holds a balance on the
        // forked chain, and `_refundExcessNative` would hand that to the first caller, breaking
        // every ETH-delta assertion for reasons unrelated to the code. Zero it here; the
        // stranded-ETH behaviour is tested deliberately in integration/V4Swap.t.sol.
        vm.deal(address(proxy), 0);

        // The scenario every one of these tests is about: a user who has granted the proxy an
        // unlimited allowance and then walks away. Their tokens stay in their own wallet, so the
        // allowance is the only thing standing between the outsider and the funds.
        _fund(approver, fundUsdc, fundWeth);
        _fund(outsider, fundUsdc, fundWeth);

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        IERC20(DAI).approve(address(proxy), type(uint256).max);
        // USDT is the reason TransferHelper exists: its approve/transferFrom return NOTHING, so an
        // IERC20 call here reverts trying to ABI-decode a bool from empty returndata. Approving it
        // raw keeps the fixture honest about what a real integrator faces.
        // (It also reverts on a non-zero -> non-zero approve, so this is only ever set once.)
        _rawApprove(USDT, address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Mirrors `getNetworkConfig` in script/DeployUniswapProxy.s.sol. Kept in sync by the
    /// factory/manager assertions in setUp, which fail loudly if the proxy was deployed for a
    /// different chain than the one being forked.
    function _loadNetwork() internal {
        if (block.chainid == 1 || block.chainid == 31337) {
            V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
            USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
            DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
            USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
            USDC_WETH_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
            V4_FEE = 500;
            V4_TICK_SPACING = 10;
            hasCanonicalTokens = true;

            tradeUsdc = 10_000e6;
            tradeWeth = 1 ether;
            lpUsdc = 10_000e6;
            lpWeth = 5 ether;
            fundUsdc = 500_000e6;
            fundWeth = 200 ether;
            return;
        }
        if (block.chainid == 11155111) {
            V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
            WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
            USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            // Sepolia has no canonical USDT/DAI worth testing against. Pointing them at the two
            // tokens that do exist keeps the fixture running; it does mean the USDT-specific
            // "returns no bool" coverage only has teeth on mainnet.
            USDT = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            DAI = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
            USDC_WETH_500 = 0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1;
            USDC_WETH_3000 = 0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50;
            // Sepolia's v4 ETH/USDC pool is live and initialised at fee 500 / spacing 10, same key
            // shape as mainnet's (verified by reading slot0 out of the PoolManager).
            V4_FEE = 500;
            V4_TICK_SPACING = 10;
            hasCanonicalTokens = false;

            // These pools hold real but thin liquidity (~1.6e16 L on the 0.05% tier), so orders are
            // ~4 orders of magnitude smaller. Everything still executes; it just does not move the
            // price into the next county.
            tradeUsdc = 1e6;
            tradeWeth = 0.0002 ether;
            lpUsdc = 2e6;
            lpWeth = 0.0005 ether;
            fundUsdc = 1_000e6;
            fundWeth = 10 ether;
            return;
        }
        revert("ForkBase: unknown chain");
    }

    /// @dev Gates tests about a specific mainnet token's behaviour (not about liquidity).
    function _requireCanonicalTokens() internal {
        vm.skip(!hasCanonicalTokens);
    }

    /// @dev approve() for tokens that do not return a bool (USDT and friends).
    function _rawApprove(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok, "raw approve failed");
    }

    // --- Helpers ---------------------------------------------------------------

    /// @notice A labelled EOA that is guaranteed to have no code on the fork.
    /// @dev `makeAddr` hashes a label into an address with no regard for what is deployed there on
    /// the forked chain. `makeAddr("outsider")` lands on 0x9dF0C6…6B4e, a live mainnet sweeper
    /// contract whose fallback forwards its whole balance elsewhere — silently invalidating any
    /// test that measures that actor's ETH. Salt the label until the address is genuinely empty.
    function _actor(string memory label) internal returns (address who) {
        for (uint256 i = 0; i < 64; i++) {
            string memory salted = i == 0 ? label : string.concat(label, "#", vm.toString(i));
            who = makeAddr(salted);
            if (who.code.length == 0) {
                vm.label(who, label);
                return who;
            }
        }
        revert("no code-free address for label");
    }

    function _fund(address who, uint256 stableAmount, uint256 wethAmount) internal {
        deal(USDC, who, stableAmount);
        deal(USDT, who, stableAmount);
        deal(DAI, who, stableAmount * 1e12);
        deal(WETH, who, wethAmount);
        vm.deal(who, wethAmount);
    }

    /// @dev Snapshot of everything the approver could plausibly lose through the proxy's allowances.
    function _approverHoldings() internal view returns (uint256[4] memory h) {
        h[0] = IERC20(USDC).balanceOf(approver);
        h[1] = IERC20(WETH).balanceOf(approver);
        h[2] = IERC20(USDT).balanceOf(approver);
        h[3] = IERC20(DAI).balanceOf(approver);
    }

    function _assertApproverUntouched(uint256[4] memory before, string memory ctx) internal view {
        uint256[4] memory nowHeld = _approverHoldings();
        assertEq(nowHeld[0], before[0], string.concat(ctx, ": USDC moved"));
        assertEq(nowHeld[1], before[1], string.concat(ctx, ": WETH moved"));
        assertEq(nowHeld[2], before[2], string.concat(ctx, ": USDT moved"));
        assertEq(nowHeld[3], before[3], string.concat(ctx, ": DAI moved"));
    }

    /// @dev A tick range straddling the current price, aligned to the pool's spacing.
    function _rangeAroundSpot(address pool, int24 widthInSpacings) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        int24 spacing = IUniswapV3PoolMinimal(pool).tickSpacing();
        int24 centre = (tick / spacing) * spacing;
        lower = centre - widthInSpacings * spacing;
        upper = centre + widthInSpacings * spacing;
    }

    function _poolFor(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return PoolAddress.computeAddress(V3_FACTORY, PoolAddress.getPoolKey(tokenA, tokenB, fee));
    }
}
