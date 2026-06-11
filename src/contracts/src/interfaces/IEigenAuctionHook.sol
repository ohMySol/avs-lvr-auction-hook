// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IAuctionServiceManager} from "./IAuctionServiceManager.sol";

/// @notice Per-position reward bookkeeping. Currency-indexed arrays use 0 = currency0, 1 = currency1.
/// @dev Liquidity is split into `liquidity` (mature — eligible for rewards) and `freshLiquidity`
/// (added in `freshBlock`, not yet eligible). Fresh liquidity matures — folding into `liquidity` —
/// once a later block is reached. This is the JIT guard: liquidity added in a block cannot earn that
/// block's arbitrage, so the atomic add ==> arb ==> remove attack accrues nothing.
/// @param liquidity Mature, reward-eligible liquidity.
/// @param freshLiquidity Liquidity added in `freshBlock`, not yet matured.
/// @param freshBlock Block in which the current `freshLiquidity` was added.
/// @param lastGrowthInsideX128 Inside-growth checkpoints (per currency) for `liquidity`.
/// @param freshGrowthInsideX128 Inside-growth checkpoints (per currency) for `freshLiquidity`.
/// @param owed Settled-but-unclaimed reward balances (per currency).
struct Position {
    uint128 liquidity;
    uint128 freshLiquidity;
    uint256 freshBlock;
    uint256[2] lastGrowthInsideX128;
    uint256[2] freshGrowthInsideX128;
    uint256[2] owed;
}

/// @notice Per-pool snapshot of in-range liquidity added during the current block — the JIT cohort
/// that must be excluded from this block's arb reward share. Packs into a single storage slot.
/// @param blockNumber Block this snapshot belongs to; a stale value means `inRange` is treated as 0.
/// @param inRange Fresh in-range liquidity added during `blockNumber`.
struct FreshLiquidity {
    uint64 blockNumber;
    uint128 inRange;
}

/// @notice Payload passed through `poolManager.unlock` for an LP add/remove routed through the hook.
/// @dev `liquidityDelta` is positive to add and negative to remove; `lp` is the real position owner
/// the hook attributes the reward ledger to (the hook itself is the V4-level position owner).
/// @param key The pool being modified.
/// @param lp The liquidity provider that owns the position.
/// @param tickLower Lower tick of the position's range.
/// @param tickUpper Upper tick of the position's range.
/// @param liquidityDelta Signed liquidity change applied to the position.
struct LiquidityCallback {
    PoolKey key;
    address lp;
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
}

/// @title IEigenAuctionHook
/// @author ohMySol
/// @notice Interface for `EigenAuctionHook` — a Uniswap V4 hook that implements a locked
/// LVR auction secured by an EigenLayer AVS.
///
/// Pool locking
/// -------------
/// Once a settler is registered via `setSettler`, all swaps against the pool must originate from
/// that settler contract. Any other caller is rejected unless `FALLBACK_PERIOD` consecutive blocks
/// have elapsed without a recorded settlement, in which case the pool re-opens to public routing.
///
/// LP rewards
/// ----------
/// The settler flags the top-of-block arb swap with `hookData = abi.encode(true)`. The hook
/// intercepts it in `afterSwap`, reads the committed bid from the AVS, skims that amount from
/// the swap output via `afterSwapReturnDelta`, and folds it into a per-tick reward-growth
/// accumulator. In-range LPs claim rewards proportional to their liquidity, V3 fee-growth style.
interface IEigenAuctionHook {
    /// @notice The service manager that commits the per-block auction winner and bid amount.
    function avs() external view returns (IAuctionServiceManager);

    /// @notice Address authorised to call `setSettler` (and nothing else after that).
    function owner() external view returns (address);

    /// @notice The sole address permitted to initiate swaps while the venue is locked.
    /// `address(0)` means the settler has not yet been registered (open mode).
    function settler() external view returns (address);

    /// @notice The last block number in which `recordSettlement` was successfully called.
    function lastSettledBlock() external view returns (uint256);

    /// @notice Pool-wide cumulative reward growth per unit of liquidity, X128 fixed point.
    /// @param poolId The pool to query.
    /// @param currencyIndex 0 for currency0, 1 for currency1.
    function rewardGrowthGlobalX128(PoolId poolId, uint256 currencyIndex) external view returns (uint256);

    /// @notice Register the settler. Callable exactly once by the owner.
    /// @dev Sets `lastSettledBlock` to the current block so the fallback timer starts from now.
    /// @param _settler Address of the deployed `Settler` contract.
    function setSettler(address _settler) external;

    /// @notice Called by the settler at the start of each settlement round to reset the
    /// fallback liveness timer. Reverts if `msg.sender != settler`.
    function recordSettlement() external;

    /* LP ACTIONS */

    /// @notice Supplies liquidity to the pool through the hook itself, so the hook can attribute the
    /// position — and the LVR rewards it earns — to the calling LP.
    /// @dev The hook is the contract V4 sees as the position owner, so an LP cannot add liquidity to
    /// this pool through a generic router and still claim rewards: routing through here is the
    /// supported path. The caller must have approved the hook to pull both currencies. The position
    /// is keyed in the reward ledger by the caller; same-block adds are JIT-guarded as usual.
    ///
    /// @param key The pool to add liquidity to.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param liquidity Liquidity units to add.
    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external;

    /// @notice Withdraws liquidity previously supplied through `addLiquidity`, returning principal
    /// (and accrued swap fees) to the caller.
    /// @dev Does not auto-claim LVR rewards — those are settled into the position and remain claimable
    /// via `claimRewards`. Reverts if the caller tries to remove more than their tracked position.
    ///
    /// @param key The pool to remove liquidity from.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param liquidity Liquidity units to remove.
    function removeLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external;

    /// @notice Claims the caller's accrued rewards for a single liquidity position, in both currencies.
    /// @dev Settles the position then transfers its full pending currency0 and currency1 balances.
    /// Reverts with `EigenAuctionHook_NothingToClaim` when there is nothing to claim.
    /// The caller must be the position owner recorded on add-liquidity.
    ///
    /// @param key The pool the position belongs to.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt Salt that distinguishes positions over the same range.
    function claimRewards(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt) external;

    /// @notice Returns the rewards a position has accrued (settled plus not-yet-settled), per currency.
    /// @dev Read-only; does not transfer anything. The caller need not be the position owner.
    ///
    /// @param key The pool the position belongs to.
    /// @param owner The position owner.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt Salt that distinguishes positions over the same range.
    /// @return amount0 Claimable reward in currency0.
    /// @return amount1 Claimable reward in currency1.
    function earned(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the liquidity the hook attributes to a position.
    ///
    /// @param key The pool the position belongs to.
    /// @param owner The position owner.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt Salt that distinguishes positions over the same range.
    function positionLiquidity(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint128);
}
