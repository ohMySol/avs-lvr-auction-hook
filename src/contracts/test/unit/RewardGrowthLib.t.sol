// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

import {RewardGrowthLib} from "../../src/libraries/RewardGrowthLib.sol";

/// @notice Unit tests for the pure reward-growth math. Mirrors Uniswap V3's fee-growth-inside
/// accounting, changed for distributing a one time arbitrage bid to in-range liquidity.
contract RewardGrowthLibTest is Test {
    uint256 constant Q128 = FixedPoint128.Q128;

    /* growthInside Tests*/

    /// @dev With both tick boundaries' outside-growth at zero and the current tick inside the
    /// range, all global growth is "inside" the position.
    function test_growthInside_AllInside_When_Outsides_Zero() public pure {
        uint256 inside = RewardGrowthLib.growthInside({
            currentTick: 0,
            tickLower: -60,
            tickUpper: 60,
            growthGlobalX128: 5 * Q128,
            lowerOutsideX128: 0,
            upperOutsideX128: 0
        });
        assertEq(inside, 5 * Q128);
    }

    /// @dev When the current tick sits below the range, the "below" component is
    /// (global - lowerOutside); a fully-outside position accrues zero inside growth.
    function test_growthInside_Zero_When_Tick_Below_Range() public pure {
        // currentTick (-120) < tickLower (-60), so: below = global - lowerOutside = 5Q - 0 = 5Q
        // currentTick (-120) < tickUpper  (60),  so: above = upperOutside = 0 ; inside = global - below - above  = 5Q - 5Q - 0 = 0
        uint256 inside = RewardGrowthLib.growthInside({
            currentTick: -120,
            tickLower: -60,
            tickUpper: 60,
            growthGlobalX128: 5 * Q128,
            lowerOutsideX128: 0,
            upperOutsideX128: 0
        });
        assertEq(inside, 0);
    }

    /// @dev When the current tick sits above the range, the "above" component is
    /// (global - upperOutside). With upperOutside = 0 the whole global is subtracted ==> inside 0.
    function test_growthInside_Zero_When_Tick_Above_Range() public pure {
        uint256 inside = RewardGrowthLib.growthInside({
            currentTick: 120,
            tickLower: -60,
            tickUpper: 60,
            growthGlobalX128: 5 * Q128,
            lowerOutsideX128: 0,
            upperOutsideX128: 0
        });
        assertEq(inside, 0);
    }

    /* rewardsOf Tests*/

    /// @dev A growth delta of exactly 1·Q128 over `liquidity` units pays out `liquidity` tokens.
    function test_rewardsOf_UnitGrowth_Pays_Liquidity() public pure {
        uint256 owed = RewardGrowthLib.rewardsOf({
            insideNowX128: 3 * Q128,
            lastInsideX128: 2 * Q128,
            liquidity: 1_000
        });
        assertEq(owed, 1_000);
    }

    /// @dev No growth since the last checkpoint ==> nothing owed.
    function test_rewardsOf_Zero_When_No_Growth() public pure {
        uint256 owed = RewardGrowthLib.rewardsOf({
            insideNowX128: 7 * Q128,
            lastInsideX128: 7 * Q128,
            liquidity: 12_345
        });
        assertEq(owed, 0);
    }

    /// @dev Fractional growth: half of Q128 over 1000 liquidity pays 500.
    function test_rewardsOf_FractionalGrowth() public pure {
        uint256 owed = RewardGrowthLib.rewardsOf({
            insideNowX128: Q128 / 2,
            lastInsideX128: 0,
            liquidity: 1_000
        });
        assertEq(owed, 500);
    }
}
