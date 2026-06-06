import "dotenv/config";
import { createPublicClient, http, type Address } from "viem";
import type { PoolKeyT } from "./types";

const env = (k: string): string => {
    const v = process.env[k];
    if(!v) throw new Error(`Environment variable ${k} is not set`);
    return v;
}

// will be changed in teh futue to support multiple chains and dynamic pool keys
export const config = {
    rpcUrl: env("RPC_URL"),
    chainId: Number(env("CHAIN_ID")),
    redisUrl: env("REDIS_URL"),
    stateView: env("STATE_VIEW") as Address,
    settler: env("SETTLER") as Address,
    asm: env("AUCTION_SERVICE_MANAGER") as Address,
    hook: env("HOOK") as Address,
    intentPort: Number(process.env.INTENT_PORT ?? "8088"),
    operatorPk: process.env.OPERATOR_PK as `0x${string}` | undefined,
    settlerCallerPk: process.env.SETTLER_CALLER_PK as `0x${string}` | undefined,
    priceSource: process.env.PRICE_SOURCE ?? "fixed",
    fixedPrice: Number(process.env.FIXED_PRICE ?? "2000"),
}

// will be changed in teh futue to support multiple chains and dynamic pool keys
export const poolKey: PoolKeyT = {
    currency0: env("CURRENCY0") as Address,
    currency1: env("CURRENCY1") as Address,
    fee: Number(env("FEE")),
    tickSpacing: Number(env("TICK_SPACING")),
    hooks: env("HOOK") as Address,
}

export function requireOperatorKeys() {
    if (!config.operatorPk || !config.settlerCallerPk) {
        throw new Error("OPERATOR_PK/SETTLER_CALLER_PK required");
    }
    
    return { 
        operatorPk: config.operatorPk, 
        settlerCallerPk: config.settlerCallerPk 
    };
}
