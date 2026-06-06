// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EigenAuctionHook} from "../../src/EigenAuctionHook.sol";
import {MockAuctionServiceManager} from "../mocks/MockAuctionServiceManager.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";

/// @notice Unit tests for the `EigenAuctionHook`.
contract EigenAuctionHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    EigenAuctionHook public hook;
    MockAuctionServiceManager public mockAvs;
    PoolKey public poolKey;
    PoolId public poolId;

    bytes public constant ARB = abi.encode(true);

    address public lpRouter; // == address(modifyLiquidityRouter), the sender the hook records as the LP

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        mockAvs = new MockAuctionServiceManager();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG | 
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | 
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | 
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        
        address hookAddress = address(flags);
        // `deployCodeTo` - allows to deploy contract at an arbitrary address.
        // It compiles the `EigenAuctionHook.sol` with the given constructor arguments into bytecode.
        // And after that injects this bytecode directly at `hookAddress`. 
        deployCodeTo("EigenAuctionHook.sol", abi.encode(address(manager), address(mockAvs), address(this)), hookAddress);

        hook = EigenAuctionHook(payable(hookAddress));

        (poolKey, poolId) = initPool(currency0, currency1, hook, 3000, 60, SQRT_PRICE_1_1);

        lpRouter = address(modifyLiquidityRouter);
    }

    /* HELPERS */

    function _bal(Currency c, address a) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(a);
    }

    /// @dev Adds liquidity over a symmetric range straddling the current tick (so it is in range).
    function _addLiquidity(int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600, 
                tickUpper: 600, 
                liquidityDelta: delta, 
                salt: salt
            }),
            new bytes(0)
        );
    }

    /// @dev Runs an arb-flagged swap (the arb flag is set in `ARB`).
    function _arbSwap() internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ARB
        );
    }

    /// @dev The LVR the hook skimmed into itself, denominated in currency1 (the arb swap output).
    /// The hook now derives this from realised price impact, so tests assert against it directly
    /// rather than a pre-committed bid.
    function _skimmed() internal view returns (uint256) {
        return _bal(currency1, address(hook));
    }

    /* TESTS */

    function test_SoleLP_Earns_Whole_LVR_In_Output_Currency() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1); // mature the LP so it predates the arb block
        _arbSwap();

        // The hook measured a positive LVR and skimmed it in currency1 (the zeroForOne output).
        uint256 lvr = _skimmed();
        assertGt(lvr, 0);

        (uint256 amount0, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertEq(amount0, 0);
        assertApproxEqAbs(amount1, lvr, 2); // sole LP earns the whole skim
    }

    function test_Reward_Splits_Proportionally_Between_Two_LPs() public {
        _addLiquidity(1e18, bytes32(0)); // LP A
        _addLiquidity(3e18, bytes32(uint256(1))); // LP B, distinct salt ==> distinct position

        vm.roll(block.number + 1); // mature both LPs before the arb block
        _arbSwap();

        uint256 lvr = _skimmed();
        (, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        (, uint256 amount1B) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(uint256(1)));

        // 1:3 split of the whole skim, in currency1.
        assertApproxEqAbs(amount1, lvr / 4, 2);
        assertApproxEqAbs(amount1B, (lvr * 3) / 4, 2);
    }

    function test_OutOfRange_LP_Earns_Nothing() public {
        _addLiquidity(1e18, bytes32(0)); // in-range LP

        // Out-of-range position: entirely above the current tick (0), earns nothing.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: 1200, 
                tickUpper: 1800, 
                liquidityDelta: 5e18, 
                salt: bytes32(uint256(2))
            }),
            new bytes(0)
        );

        vm.roll(block.number + 1); // mature both LPs before the arb block
        _arbSwap();

        (uint256 amount0, uint256 amount1) = hook.earned(poolKey, lpRouter, 1200, 1800, bytes32(uint256(2)));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (, uint256 amount1A) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertApproxEqAbs(amount1A, _skimmed(), 2);
    }

    function test_claimRewards_Pays_And_Reverts_On_Second_Claim() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1); // mature the LP so it predates the arb block
        _arbSwap();
        uint256 lvr = _skimmed();

        // Rewards are an ERC20 (currency1), so the LP router can receive them directly.
        uint256 before = _bal(currency1, lpRouter);
        vm.prank(lpRouter);
        hook.claimRewards(poolKey, -600, 600, bytes32(0));
        assertApproxEqAbs(_bal(currency1, lpRouter) - before, lvr, 2);

        // Nothing left to claim.
        vm.prank(lpRouter);
        vm.expectRevert(ErrorsLib.EigenAuctionHook_NothingToClaim.selector);
        hook.claimRewards(poolKey, -600, 600, bytes32(0));
    }

    /// @notice The core JIT test: liquidity added, used to back the arb, and removed all within the
    /// arb block earns nothing — and does not dilute the honest LP, who still gets the whole skim.
    function test_JIT_AddArbRemove_SameBlock_Earns_Nothing() public {
        _addLiquidity(1e18, bytes32(0)); // honest LP
        vm.roll(block.number + 1); // honest LP matures into the arb block

        // JIT: add a large in-range position in the arb block, run the arb, then pull it — same block.
        _addLiquidity(5e18, bytes32(uint256(7)));
        _arbSwap();
        _addLiquidity(-5e18, bytes32(uint256(7)));

        // JIT earned nothing.
        (uint256 j0, uint256 j1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(uint256(7)));
        assertEq(j0, 0);
        assertEq(j1, 0);

        // Honest LP still earns the whole skim — JIT liquidity was excluded from the denominator.
        (, uint256 h1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertApproxEqAbs(h1, _skimmed(), 2);
    }

    /// @notice Even a non-malicious LP that adds in the arb block earns nothing for that arb —
    /// rewards require predating the block. This is the same rule that defeats JIT. With this LP the
    /// only in-range liquidity, no one is reward-eligible, so the hook skims nothing at all.
    function test_FreshLP_In_Arb_Block_Earns_Nothing_That_Block() public {
        _addLiquidity(1e18, bytes32(0)); // added in the arb block ==> fresh
        _arbSwap();

        (, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertEq(amount1, 0);
        assertEq(_skimmed(), 0); // nobody eligible ⇒ nothing skimmed (no stranded funds)
    }

    /// @dev The hook prices LVR from realised swap state alone — no AVS winner, no committed bid.
    /// In open mode (no settler) an arb-flagged swap from a mature LP still produces an LVR skim.
    function test_OpenMode_ArbSwap_Skims_LVR_Without_AVS() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1); // mature the LP
        _arbSwap();
        assertGt(_skimmed(), 0);
    }

    /// @dev Once a settler is registered the pool is locked: swaps not originating from the
    /// settler revert in beforeSwap.
    function test_NonSettlerSwap_Reverts_When_Settler_Set() public {
        hook.setSettler(address(0xBEEF));

        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    /// @dev After FALLBACK_PERIOD blocks with no settlement the pool re-opens to public routing.
    function test_Swap_Passes_After_Fallback_Period_Elapses() public {
        hook.setSettler(address(0xBEEF));
        vm.roll(block.number + ConstantsLib.FALLBACK_PERIOD + 1);

        _addLiquidity(1e18, bytes32(0));
        // Fallback window passed — public swaps allowed again.
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    function test_NormalSwap_Passes_Through() public {
        _addLiquidity(1e18, bytes32(0));
        // No arb flag ==> no winner needed, no bid taken.
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, 
                amountSpecified: -0.01 ether, 
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
        assertEq(_bal(currency1, address(hook)), 0);
    }
}
