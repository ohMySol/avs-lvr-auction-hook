import type { Hex, Address } from "viem";

export interface PoolKeyT {
    currency0: Address;
    currency1: Address;
    fee: number;
    tickSpacing: number;
    hooks: Address;
}

export interface SwapIntentT {
    user: Address; 
    poolId: Hex;
    zeroForOne: boolean;
    amountIn: bigint; 
    minAmountOut: bigint; 
    nonce: bigint; 
    deadline: bigint; 
    signature: Hex;   
}

export interface SwapParamsT {
    zeroForOne: boolean; 
    amountSpecified: bigint; 
    sqrtPriceLimitX96: bigint;
}

export interface WinnerTupleT {
    poolId: Hex;
    targetBlock: bigint;
    winner: Address;
    bidAmount: bigint;
}

// A searcher's signed offer for the exclusive arb right in a block. The signature is over the
// challenge-proof hash (poolId, targetBlock, bidAmount), so a losing bid doubles as fraud-proof
// evidence if a lower winner was committed.
export interface SignedBidT {
    poolId: Hex;
    targetBlock: bigint;
    bidder: Address;
    bidAmount: bigint;
    signature: Hex;
}

// Structural source of arb bids for a block, mirroring IntentSource. Lets the operator loop depend
// on the shape, not searcher-rpc's concrete Redis queue.
export interface BidSource {
    drainBids(): Promise<SignedBidT[]>;
}

// Structural type so avs-auction never imports searcher-rpc's concrete mempool.
export interface IntentSource { 
    drain(): Promise<SwapIntentT[]>; 
}