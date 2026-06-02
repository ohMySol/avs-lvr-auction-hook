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
}