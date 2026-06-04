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
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {EigenAuctionHook} from "../../src/EigenAuctionHook.sol";
import {MockAuctionServiceManager} from "../mocks/MockAuctionServiceManager.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

/// @notice Unit tests for the `EigenAuctionHook`.
contract EigenAuctionHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    EigenAuctionHook public hook;
    MockAuctionServiceManager public mockAvs;
    PoolKey public poolKey;
    PoolId public poolId;

    // Bid denominated in the swap's output currency (currency1 for a zeroForOne exact-input swap),
    // kept well below the swap output so the winner can cover it.
    uint256 public constant BID = 0.001 ether;
    bytes public constant ARB = abi.encode(true);

    address public winnerRouter; // == address(swapRouter), the sender the hook sees as the arbitrage winner
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
        deployCodeTo("EigenAuctionHook.sol", abi.encode(address(manager), address(mockAvs), ""), hookAddress);

        hook = EigenAuctionHook(payable(hookAddress));

        (poolKey, poolId) = initPool(currency0, currency1, hook, 3000, 60, SQRT_PRICE_1_1);

        winnerRouter = address(swapRouter);
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

    /// @dev Runs the arb swap as `winnerRouter` (the arb flag is set in `ARB`).
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

    /// @dev Commits `winnerRouter` as winner for this block, then runs the arb swap. The bid is
    /// skimmed atomically from the swap output.
    function _commitAndArb() internal {
        bytes[] memory noSigs;
        mockAvs.commitWinner(poolId, block.number, winnerRouter, BID, noSigs);
        _arbSwap();
    }

    /* TESTS */

    function test_SoleLP_Earns_Whole_Bid_In_Output_Currency() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1); // mature the LP so it predates the arb block
        _commitAndArb();

        // The bid was skimmed in currency1 (the zeroForOne output) and is held by the hook.
        assertEq(_bal(currency1, address(hook)), BID);

        (uint256 amount0, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertEq(amount0, 0);
        assertApproxEqAbs(amount1, BID, 2);
    }

    function test_Reward_Splits_Proportionally_Between_Two_LPs() public {
        _addLiquidity(1e18, bytes32(0)); // LP A
        _addLiquidity(3e18, bytes32(uint256(1))); // LP B, distinct salt ==> distinct position

        vm.roll(block.number + 1); // mature both LPs before the arb block
        _commitAndArb();

        (uint256 amount0, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        (uint256 amount0B, uint256 amount1B) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(uint256(1)));

        // 1:3 split of the whole bid, in currency1.
        assertApproxEqAbs(amount1, BID / 4, 2);
        assertApproxEqAbs(amount1B, (BID * 3) / 4, 2);
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
        _commitAndArb();

        (uint256 amount0, uint256 amount1) = hook.earned(poolKey, lpRouter, 1200, 1800, bytes32(uint256(2)));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (uint256 amount0A, uint256 amount1A) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertApproxEqAbs(amount1A, BID, 2);
    }

    function test_claimRewards_Pays_And_Reverts_On_Second_Claim() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1); // mature the LP so it predates the arb block
        _commitAndArb();

        // Rewards are an ERC20 (currency1), so the LP router can receive them directly.
        uint256 before = _bal(currency1, lpRouter);
        vm.prank(lpRouter);
        hook.claimRewards(poolKey, -600, 600, bytes32(0));
        assertApproxEqAbs(_bal(currency1, lpRouter) - before, BID, 2);

        // Nothing left to claim.
        vm.prank(lpRouter);
        vm.expectRevert(ErrorsLib.EigenAuctionHook_NothingToClaim.selector);
        hook.claimRewards(poolKey, -600, 600, bytes32(0));
    }

    /// @notice The core JIT test: liquidity added, used to back the arb, and removed all within the
    /// arb block earns nothing — and does not dilute the honest LP, who still gets the whole bid.
    function test_JIT_AddArbRemove_SameBlock_Earns_Nothing() public {
        _addLiquidity(1e18, bytes32(0)); // honest LP
        vm.roll(block.number + 1); // honest LP matures into the arb block

        bytes[] memory noSigs;
        mockAvs.commitWinner(poolId, block.number, winnerRouter, BID, noSigs);

        // JIT: add a large in-range position in the arb block, run the arb, then pull it — same block.
        _addLiquidity(5e18, bytes32(uint256(7)));
        _arbSwap();
        _addLiquidity(-5e18, bytes32(uint256(7)));

        // JIT earned nothing.
        (uint256 j0, uint256 j1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(uint256(7)));
        assertEq(j0, 0);
        assertEq(j1, 0);

        // Honest LP still earns the whole bid — JIT liquidity didn't dilute the denominator.
        (, uint256 h1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertApproxEqAbs(h1, BID, 2);
    }

    /// @notice Even a non-malicious LP that adds in the arb block earns nothing for that arb —
    /// rewards require predating the block. This is the same rule that defeats JIT.
    function test_FreshLP_In_Arb_Block_Earns_Nothing_That_Block() public {
        bytes[] memory noSigs;
        mockAvs.commitWinner(poolId, block.number, winnerRouter, BID, noSigs);

        _addLiquidity(1e18, bytes32(0)); // added in the arb block ==> fresh
        _arbSwap();

        (, uint256 amount1) = hook.earned(poolKey, lpRouter, -600, 600, bytes32(0));
        assertEq(amount1, 0);
    }

    function test_ArbSwap_Reverts_When_No_Committed_Winner() public {
        _addLiquidity(1e18, bytes32(0));
        // No commitWinner ==> beforeSwap must revert (wrapped by the PoolManager).
        vm.expectRevert();
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

    function test_ArbSwap_Reverts_When_Result_Challenged() public {
        _addLiquidity(1e18, bytes32(0));
        vm.roll(block.number + 1);

        bytes[] memory noSigs;
        mockAvs.commitWinner(poolId, block.number, winnerRouter, BID, noSigs);
        mockAvs.markChallenged(poolId, block.number);

        vm.expectRevert(); // beforeSwap reverts on a challenged result (wrapped by the PoolManager)
        _arbSwap();
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
