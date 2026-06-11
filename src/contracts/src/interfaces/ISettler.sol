// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {IAuctionServiceManager} from "./IAuctionServiceManager.sol";

/// @notice An off-chain swap intent signed by the user.
///
/// Users sign this struct (EIP-712) and deliver it to the operator's private RPC rather than
/// broadcasting a transaction. The winning operator batches received intents into `settle`.
///
/// @param user Signer and token source / recipient.
/// @param poolId `PoolId.unwrap(key.toId())` — binds the intent to a specific pool,
/// preventing cross-pool replay when the same settler serves multiple pools.
/// @param zeroForOne Swap direction: currency0 → currency1 when `true`.
/// @param amountIn Exact input amount the settler is authorised to pull from `user`.
/// @param minAmountOut Minimum output the user accepts; the fill reverts if not met.
/// @param nonce Single-use value for replay protection (bitmap scheme, not sequential).
/// Users choose any unused 64-bit value; call `isNonceUsed` to check.
/// @param deadline Latest `block.timestamp` at which this intent may be filled.
/// @param signature 65-byte ECDSA (r, s, v) over the EIP-712 struct hash.
struct SwapIntent {
    address user;
    bytes32 poolId;
    bool    zeroForOne;
    uint128 amountIn;
    uint128 minAmountOut;
    uint64  nonce;
    uint64  deadline;
    bytes   signature;
}

/// @title ISettler
/// @author ohMySol
/// @notice Chain-wide settlement entry point for all EigenAuction pools.
///
/// One Settler is deployed per chain. Each `EigenAuctionHook` registers it via `setSettler`.
/// The AVS-committed winning operator calls `settle(key, arb, intents)` once per pool per block.
///
/// Step 1 — Top-of-block arb rebalance.
/// A single swap that moves the pool to the external price. The hook skims the operator's
/// committed bid from the output and distributes it to in-range LPs via the reward-growth accumulator.
///
/// Step 2 — User intent fills.
/// Each signed `SwapIntent` is signature-verified, pool-checked, and filled at the post-arb price.
/// Users bypass the public mempool entirely; their intents are delivered to the operator's private RPC.
///
/// Both steps execute inside a single Uniswap V4 flash-accounting unlock, so all token flows
/// are atomic and revert together on any failure.
///
/// Fallback
/// --------
/// If no settlement lands for `FALLBACK_PERIOD` consecutive blocks, the hook re-opens that pool
/// to unrestricted public swaps, preventing the venue lock from becoming a liveness failure.
interface ISettler {
    /* SETTLEMENT */

    /// @notice Settle a block for `key`: execute the arb rebalance (Step 1) then fill user intents (Step 2).
    ///
    /// @dev Caller must be the AVS-committed winner for `key.toId()` at `block.number`. The function:
    ///   1. Verifies the AVS result (committed, not challenged, caller is winner).
    ///   2. Calls `hook.recordSettlement()` on `key.hooks` to reset the fallback timer.
    ///   3. Calls `poolManager.unlock`, inside which all swaps execute atomically.
    ///
    /// Inside the unlock, if `arb.amountSpecified != 0`:
    ///   a. The caller's `rewardAmount` of currency0 is pulled via transferFrom and deposited into
    ///      the pool manager (sync + transferFrom + settle) BEFORE the arb swap. The hook collects
    ///      this in `afterSwap` and distributes it to in-range LPs. The caller must have pre-approved
    ///      this contract for at least `rewardAmount` of the pool's currency0.
    ///   b. The current pool liquidity is read and passed as `expectedLiquidity` in hookData, so the
    ///      hook can detect and revert on any JIT add that lands between this read and the swap.
    ///
    /// Reverts if both `arb.amountSpecified == 0` and `intents` is empty.
    /// Reverts if any intent's `poolId` does not match `key.toId()`.
    ///
    /// @param key The pool to settle.
    /// @param rewardAmount Amount of currency0 to pay to LPs as the arb reward. The caller must have
    ///        approved this contract for at least this amount. Pass 0 to skip the reward payment.
    /// @param arb Top-of-block rebalance swap. Set `amountSpecified = 0` to skip Step 1.
    /// @param intents Ordered list of user intents to fill at the post-arb price.
    function settle(PoolKey calldata key, uint256 rewardAmount, SwapParams calldata arb, SwapIntent[] calldata intents) external;

    /* NONCE MANAGEMENT */

    /// @notice Cancel a nonce so the corresponding pending intent can never be filled.
    /// @param nonce The nonce to invalidate.
    function invalidateNonce(uint64 nonce) external;

    /// @notice Returns `true` if `nonce` has been used or explicitly invalidated for `user`.
    function isNonceUsed(address user, uint64 nonce) external view returns (bool);

    /* VIEW */

    /// @notice The Uniswap V4 pool manager this settler submits swaps to.
    function poolManager() external view returns (IPoolManager);

    /// @notice The AVS service manager that commits per-block auction winners.
    function avs() external view returns (IAuctionServiceManager);

    /// @notice EIP-712 domain separator used when verifying intent signatures.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
