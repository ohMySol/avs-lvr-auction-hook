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

// Structural type so avs-auction never imports searcher-rpc's concrete mempool.
export interface IntentSource { 
    drain(): Promise<SwapIntentT[]>; 
}