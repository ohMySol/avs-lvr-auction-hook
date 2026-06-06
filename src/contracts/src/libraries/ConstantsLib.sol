// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ConstantsLib
/// @author ohMySol
/// @notice Library of constants used across the Eigen Auction contracts.
library ConstantsLib {
    /// @notice Blocks after `commitWinner` during which the result can be challenged.
    uint256 public constant CHALLENGE_WINDOW = 50;

    /// @notice EigenLayer operator-set ID this AVS uses for membership checks and slashing.
    uint32 public constant OPERATOR_SET_ID = 1;

    /// @dev Fixed-point precision for the reward-per-share accumulator.
    uint256 public constant PRECISION = 1e18;

    /// @notice Number of blocks without a settlement after which public swaps are re-allowed.
    uint256 public constant FALLBACK_PERIOD = 64;

    /// @notice Share of the measured arbitrage LVR returned to LPs, in WAD where `PRECISION` (1e18)
    /// is 100%. The remainder is left to the arbitrageur as the incentive to keep rebalancing the
    /// pool toward the market price. 0.9e18 == 90%.
    uint256 public constant LVR_SHARE_WAD = 0.9e18;
}