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

/// @title IEigenAuctionHook
/// @author ohMySol
/// @notice Interface that defines the externally callable surface of the `EigenAuctionHook`.
/// The hook enforces that only the AVS-committed auction winner may execute an arbitrage-flagged
/// swap, skims the committed bid from the swap's output currency, and folds it into a per-tick,
/// per-currency reward-growth accumulator so the captured value flows back to in-range LPs.
interface IEigenAuctionHook {
    /// @notice The service manager that commits the per-block auction winner.
    function avs() external view returns (IAuctionServiceManager);

    /// @notice poolId => pool-wide cumulative reward growth per unit of liquidity, X128 fixed point.
    /// @param poolId The pool to query.
    /// @param currencyIndex 0 for currency0, 1 for currency1.
    function rewardGrowthGlobalX128(PoolId poolId, uint256 currencyIndex) external view returns (uint256);

    /// @notice Claims the caller's accrued rewards for a single liquidity position, in both currencies.
    /// @dev Settles the position, then transfers its full pending currency0 and currency1 balances.
    /// Reverts when there is nothing to claim. The caller must be the position owner the hook recorded
    /// on add-liquidity.
    ///
    /// @param key The pool key the position belongs to.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt The salt that differentiates positions over the same range.
    function claimRewards(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt) external;

    /// @notice Returns the rewards a position has accrued (settled plus not yet settled), per currency.
    /// @dev Does not transfer anything. The caller need not be the position owner.
    ///
    /// @param key The pool key the position belongs to.
    /// @param owner The position owner.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt The salt that differentiates positions over the same range.
    /// @return amount0 Claimable reward in currency0.
    /// @return amount1 Claimable reward in currency1.
    function earned(PoolKey calldata key, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the liquidity the hook attributes to a position.
    ///
    /// @param key The pool key the position belongs to.
    /// @param owner The position owner.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param salt The salt that differentiates positions over the same range.
    /// @return The position's tracked liquidity.
    function positionLiquidity(PoolKey calldata key, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128);
}
