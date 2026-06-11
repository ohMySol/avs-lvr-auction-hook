// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IAuctionServiceManager} from "./IAuctionServiceManager.sol";

/// @notice Per-position reward bookkeeping. Rewards are always denominated in currency0.
/// @param liquidity Mature, reward-eligible liquidity.
/// @param lastGrowthInsideX128 Inside-growth checkpoint for `liquidity` (currency0 only).
/// @param owed Settled-but-unclaimed reward balance in currency0.
struct Position {
    uint128 liquidity;
    uint256 lastGrowthInsideX128;
    uint256 owed;
}

/// @notice Payload passed through `poolManager.unlock` for an LP add/remove routed through the hook.
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
/// The settler encodes `(isArb=true, rewardAmount, expectedLiquidity)` in the arb swap's hookData.
/// The hook intercepts the swap in `afterSwap`, optionally checks that actual pool liquidity matches
/// `expectedLiquidity` (JIT guard), collects `rewardAmount` of currency0 from the pre-funded pool
/// manager balance, and folds it into a per-tick reward-growth accumulator. LPs claim currency0
/// rewards proportional to their liquidity via `claimRewards`.
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
    /// Rewards are always denominated in currency0.
    /// @param poolId The pool to query.
    function rewardGrowthGlobalX128(PoolId poolId) external view returns (uint256);

    /// @notice Register the settler. Callable exactly once by the owner.
    /// @param _settler Address of the deployed `Settler` contract.
    function setSettler(address _settler) external;

    /// @notice Called by the settler at the start of each settlement round to reset the
    /// fallback liveness timer. Reverts if `msg.sender != settler`.
    function recordSettlement() external;

    /* LP ACTIONS */

    /// @notice Supplies liquidity to the pool through the hook itself.
    /// @param key The pool to add liquidity to.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param liquidity Liquidity units to add.
    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external;

    /// @notice Withdraws liquidity previously supplied through `addLiquidity`.
    /// @param key The pool to remove liquidity from.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param liquidity Liquidity units to remove.
    function removeLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external;

    /// @notice Returns the currency0 rewards a position has accrued (settled plus not-yet-settled).
    /// Rewards are paid out automatically when liquidity is removed — no separate claim step needed.
    /// @param key The pool the position belongs to.
    /// @param owner The position owner.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt Salt that distinguishes positions over the same range.
    /// @return amount Claimable reward in currency0.
    function earned(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256 amount);

    /// @notice Returns the liquidity the hook attributes to a position.
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
