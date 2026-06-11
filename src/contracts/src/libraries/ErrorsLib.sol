// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author @ohMySol
/// @notice A library that defines the errors for EigenAuction Hook smart contract system
library ErrorsLib {
    /* EigenAuctionHook Errors */

    /// @notice Thrown during construction when a required address argument is the zero address
    error EigenAuctionHook_ZeroAddress();

    /// @notice Thrown when an arb-flagged swap targets a block that has no committed auction winner
    error EigenAuctionHook_AuctionNotCommitted();

    /// @notice Thrown when an arb-flagged swap is executed by an address other than the committed winner
    error EigenAuctionHook_NotWinner();

    /// @notice Thrown when an arb-flagged swap targets a result that was invalidated by a challenge
    error EigenAuctionHook_WinnerChallenged();

    /// @notice Thrown when an LP has no rewards to claim for a position
    error EigenAuctionHook_NothingToClaim();

    /// @notice Thrown when `addLiquidity`/`removeLiquidity` is called with a zero liquidity amount
    error EigenAuctionHook_ZeroLiquidity();

    /* AuctionServiceManager / MockAuctionServiceManager Errors */

    /// @notice Thrown by MockAuctionServiceManager when the caller is not the mock owner
    error AuctionServiceManager_NotOwner();

    /// @notice Thrown when constructing with a threshold of zero
    error AuctionServiceManager_InvalidThreshold();

    /// @notice Thrown when committing a winner for a block that already has a committed result
    error AuctionServiceManager_AlreadyCommitted();

    /// @notice Thrown when committing a winner for a block that is too old (outside the commit window)
    error AuctionServiceManager_StaleBlock();

    /// @notice Thrown when the number of valid unique operator signatures is below the threshold
    error AuctionServiceManager_QuorumNotMet();

    /// @notice Thrown when committing a winner with the zero address as winner
    error AuctionServiceManager_ZeroWinner();

    /// @notice Thrown when challenging a result that has no committed winner
    error AuctionServiceManager_NotCommitted();

    /// @notice Thrown when challenging a result that was already successfully challenged
    error AuctionServiceManager_AlreadyChallenged();

    /// @notice Thrown when the challenge window (CHALLENGE_WINDOW blocks) has closed
    error AuctionServiceManager_ChallengeWindowClosed();

    /// @notice Thrown when the challenger's bid is not strictly greater than the committed bid
    error AuctionServiceManager_NotHigherBid();

    /// @notice Thrown when the bidder signature in a challenge cannot be recovered or does not match higherBidder
    error AuctionServiceManager_InvalidBidSignature();

    /// @notice Thrown when `configureSlashing` is called with arrays of mismatched length
    error AuctionServiceManager_SlashConfigLengthMismatch();

    /// @notice Thrown when an `IAVSRegistrar` hook is called by an address other than the AllocationManager
    error AuctionServiceManager_NotAllocationManager();

    /// @notice Thrown when an operator-set registration targets an AVS other than this contract
    error AuctionServiceManager_InvalidAvs();

    /// @notice Thrown when registering for an operator set id this AVS does not run
    error AuctionServiceManager_InvalidOperatorSet();

    /* Settler Errors */

    /// @notice Thrown when `unlockCallback` is called by an address other than the pool manager
    error Settler_NotPoolManager();

    /// @notice Thrown when `settle` is called by an address other than the AVS-committed winner
    error Settler_NotWinner();

    /// @notice Thrown when `settle` is called for a block with no committed auction result
    error Settler_AuctionNotCommitted();

    /// @notice Thrown when `settle` is called for a block whose committed result was challenged
    error Settler_WinnerChallenged();

    /// @notice Thrown when filling a user intent whose `deadline` has passed
    error Settler_IntentExpired();

    /// @notice Thrown when a user intent's actual output is below `minAmountOut`
    error Settler_SlippageExceeded();

    /// @notice Thrown when filling a user intent whose nonce was already used or invalidated
    error Settler_NonceUsed();

    /// @notice Thrown when a user intent carries an invalid EIP-712 signature
    error Settler_InvalidSignature();

    /// @notice Thrown when `settle` is called with no arb swap and no user intents
    error Settler_NothingToSettle();

    /// @notice Thrown when a user intent's `poolId` does not match the pool being settled
    error Settler_WrongPool();

    /* EigenAuctionHook Errors — pool lock */

    /// @notice Thrown when a swap reaches the hook from an address other than the registered settler
    /// while the fallback period has not yet elapsed
    error EigenAuctionHook_NotSettler();

    /// @notice Thrown when `setSettler` is called by a non-owner or after the settler is already set
    error EigenAuctionHook_Unauthorized();
}