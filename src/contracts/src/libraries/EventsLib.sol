// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title EventsLib
/// @author @ohMySol
/// @notice A library that defines the events for EigenAuction Hook smart contract system
library EventsLib {
    /* AuctionServiceManager Events  */

    /// @notice Emitted when `AuctionServiceManager` received an auction winner
    /// @param poolId ID of the pool
    /// @param targetBlock Block where the winner was commited
    /// @param winner Address of the auction winner
    /// @param bidAmount Amount of the winner bid
    event WinnerCommitted(
        PoolId indexed poolId,
        uint256 indexed targetBlock,
        address indexed winner,
        uint256 bidAmount
    );

    /// @notice Emitted when a committed result is successfully challenged via a higher-bid fraud proof
    /// @param poolId Pool the disputed result belongs to
    /// @param targetBlock Block number of the disputed result
    /// @param challenger Address that submitted the challenge
    /// @param higherBidder Bidder whose signed bid proved the committed winner was wrong
    /// @param higherBidAmount The ignored higher bid amount
    event WinnerChallenged(
        PoolId indexed poolId,
        uint256 indexed targetBlock,
        address indexed challenger,
        address higherBidder,
        uint256 higherBidAmount
    );

    /// @notice Emitted for each operator slashed after a successful challenge
    /// @param operator Address of the slashed operator
    /// @param slashId  Slash ID returned by AllocationManager
    event OperatorSlashed(address indexed operator, uint256 slashId);

    /// @notice Emitted when AllocationManager admits an operator into this AVS's operator set
    /// @param operator Address of the registered operator
    /// @param operatorSetId The operator set the operator joined
    event OperatorRegistered(address indexed operator, uint32 operatorSetId);

    /// @notice Emitted when AllocationManager removes an operator from this AVS's operator set
    /// @param operator Address of the deregistered operator
    /// @param operatorSetId The operator set the operator left
    event OperatorDeregistered(address indexed operator, uint32 operatorSetId);

    /* EigenAuctionHook Events  */

    /// @notice Emitted when a winning arb swap settles and the bid is folded into LP rewards
    /// @param poolId ID of the pool
    /// @param winner Address of the auction winner charged for the arb
    /// @param currencyIndex Which pool currency the bid was taken in (0 = currency0, 1 = currency1)
    /// @param bidAmount Amount distributed to the pool's in-range liquidity providers
    event ArbitrageSettled(
        PoolId indexed poolId,
        address indexed winner,
        uint8 currencyIndex,
        uint256 bidAmount
    );

    /// @notice Emitted when an LP claims rewards for a position
    /// @param poolId ID of the pool
    /// @param lp Liquidity provider (position owner) address
    /// @param amount0 Reward paid in currency0
    /// @param amount1 Reward paid in currency1
    event RewardsClaimed(
        PoolId indexed poolId,
        address indexed lp,
        uint256 amount0,
        uint256 amount1
    );

    /* Settler Events */

    /// @notice Emitted when a user swap intent is successfully filled
    /// @param poolId Pool the intent was filled against
    /// @param user Intent signer and token recipient
    /// @param zeroForOne Swap direction
    /// @param amountIn Input amount pulled from the user
    /// @param amountOut Output amount delivered to the user
    event IntentFilled(
        PoolId indexed poolId,
        address indexed user,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a user invalidates a nonce to cancel a pending intent
    /// @param user  Owner of the nonce
    /// @param nonce The invalidated nonce
    event NonceInvalidated(address indexed user, uint64 nonce);

    /// @notice Emitted when a full settlement round (arb + user intents) completes
    /// @param poolId Pool that was settled
    /// @param blockNumber Block the settlement targeted
    /// @param operator AVS winner that executed the settlement
    event BlockSettled(PoolId indexed poolId, uint256 indexed blockNumber, address indexed operator);

    /* EigenAuctionHook Events — venue lock */

    /// @notice Emitted when the settler address is registered on the hook
    /// @param settler The settler contract address
    event SettlerSet(address indexed settler);
}