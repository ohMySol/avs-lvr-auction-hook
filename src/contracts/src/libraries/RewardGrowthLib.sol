// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

/// @title RewardGrowthLib
/// @author ohMySol
/// @notice Pure reward-growth math, modelled on Uniswap V3's fee-growth-inside accounting. The
/// arbitrage bid is folded into a per-pool growth accumulator (scaled by 2**128); each tick stores
/// the growth recorded "outside" it. A position's earned rewards are the growth that accrued
/// "inside" its range since the position last checkpointed, multiplied by its liquidity.
/// @dev All growth values are X128 fixed point. Subtractions wrap on purpose — exactly as V3 does —
/// so that the inside/outside bookkeeping stays consistent as ticks are crossed.
library RewardGrowthLib {
    /// @notice Computes the reward growth accumulated inside the range `[tickLower, tickUpper]`.
    /// @param currentTick The pool's current tick.
    /// @param tickLower Lower tick of the position's range.
    /// @param tickUpper Upper tick of the position's range.
    /// @param growthGlobalX128 Pool-wide cumulative reward growth (X128).
    /// @param lowerOutsideX128 Reward growth recorded outside `tickLower` (X128).
    /// @param upperOutsideX128 Reward growth recorded outside `tickUpper` (X128).
    /// @return insideX128 Reward growth inside the range (X128).
    function growthInside(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint256 growthGlobalX128,
        uint256 lowerOutsideX128,
        uint256 upperOutsideX128
    ) internal pure returns (uint256 insideX128) {
        unchecked {
            uint256 below = currentTick >= tickLower 
                ? lowerOutsideX128 
                : growthGlobalX128 - lowerOutsideX128;
            
            uint256 above = currentTick < tickUpper 
                ? upperOutsideX128 
                : growthGlobalX128 - upperOutsideX128;
            
                insideX128 = growthGlobalX128 - below - above;
        }
    }

    /// @notice Converts the growth a position accrued since its last checkpoint into a token amount.
    /// @param insideNowX128 Current reward growth inside the position's range (X128).
    /// @param lastInsideX128 The position's checkpointed inside growth (X128).
    /// @param liquidity The position's liquidity.
    /// @return The reward amount owed to the position.
    function rewardsOf(
        uint256 insideNowX128, 
        uint256 lastInsideX128, 
        uint128 liquidity
    ) internal pure returns (uint256) {
        unchecked {
            return FullMath.mulDiv(insideNowX128 - lastInsideX128, liquidity, FixedPoint128.Q128);
        }
    }
}
