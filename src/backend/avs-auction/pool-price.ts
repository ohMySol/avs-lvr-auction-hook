// On-chain pool state reader (via StateView) plus the top-of-block arb sizing helper.
import type { Hex } from "viem";
import { config, publicClient } from "../../shared/config";
import { stateViewAbi } from "../../shared/abi";
import type { SwapParamsT } from "../../shared/types";

// Current pool price (sqrtPriceX96) and tick for a pool.
export async function getSlot0(poolId: Hex): Promise<{ sqrtPriceX96: bigint; tick: number }> {
    const [sqrtPriceX96, tick] = await publicClient.readContract({
        address: config.stateView,
        abi: stateViewAbi,
        functionName: "getSlot0",
        args: [poolId],
    });
    return { sqrtPriceX96, tick };
}

// Active in-range liquidity for a pool.
export async function getLiquidity(poolId: Hex): Promise<bigint> {
    return publicClient.readContract({
        address: config.stateView,
        abi: stateViewAbi,
        functionName: "getLiquidity",
        args: [poolId],
    });
}

// Build the arb swap that moves the pool from its current price to the external target.
// No amount-solving: set the price limit to the target and supply a large exact-in cap; the pool
// swaps until it hits the target and stops. Direction: if the pool is above target, sell token0
// (zeroForOne) to push the price down; if below, buy token0 to push it up.
export function buildArbParams(
    currentSqrtX96: bigint,
    targetSqrtX96: bigint,
    capAmountIn: bigint,
): SwapParamsT {
    const zeroForOne = currentSqrtX96 > targetSqrtX96;
    return { zeroForOne, amountSpecified: -capAmountIn, sqrtPriceLimitX96: targetSqrtX96 };
}
