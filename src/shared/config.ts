import "dotenv/config";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, http, type Address, type Hex } from "viem";
import type { PoolKeyT } from "./types";

// Trim because the Makefile's `include .env` can leave trailing whitespace on a value when the
// .env line has an inline comment (Make, unlike dotenv, does not strip it).
const env = (k: string): string => {
    const v = process.env[k];
    if(!v) throw new Error(`Environment variable ${k} is not set`);
    return v.trim();
}

const optEnv = (k: string): string | undefined => process.env[k]?.trim();

// Addresses are NOT hand-set in env. DeployFork.s.sol writes deployments/<chainId>.json and both
// this backend and the frontend read that single artifact, so a network switch is just CHAIN_ID +
// RPC_URL. Only secrets (PKs), endpoints (RPC/Redis), and price knobs stay in env.
interface DeploymentArtifact {
    chainId: number;
    poolManager: Address;
    stateView: Address;
    auctionServiceManager: Address;
    hook: Address;
    settler: Address;
    pool: {
        currency0: Address;
        currency1: Address;
        currency0Decimals: number;
        currency1Decimals: number;
        fee: number;
        tickSpacing: number;
        poolId: Hex;
    };
    deployedBlock: number;
}

const chainId = Number(env("CHAIN_ID"));

// DEPLOYMENTS_DIR lets tests point at a committed fixture; production defaults to deployments/.
function loadDeployment(): DeploymentArtifact {
    const dir = process.env.DEPLOYMENTS_DIR ?? "deployments";
    const file = resolve(dir, `${chainId}.json`);
    try {
        return JSON.parse(readFileSync(file, "utf8"));
    } catch {
        throw new Error(`Deployment artifact not found at ${file}. Run \`make deploy-fork\` first, or set DEPLOYMENTS_DIR.`);
    }
}

const deployment = loadDeployment();

export const config = {
    rpcUrl: env("RPC_URL"),
    chainId,
    redisUrl: env("REDIS_URL"),
    stateView: deployment.stateView,
    settler: deployment.settler,
    asm: deployment.auctionServiceManager,
    hook: deployment.hook,
    intentPort: Number(optEnv("INTENT_PORT") ?? "8088"),
    operatorPk: optEnv("OPERATOR_PK") as `0x${string}` | undefined,
    settlerCallerPk: optEnv("SETTLER_CALLER_PK") as `0x${string}` | undefined,
    priceSource: optEnv("PRICE_SOURCE") ?? "fixed",
    fixedPrice: Number(optEnv("FIXED_PRICE") ?? "2000"),
    // Token decimals drive the price -> sqrtPriceX96 conversion (e.g. USDC 6 / WETH 18).
    decimals0: deployment.pool.currency0Decimals,
    decimals1: deployment.pool.currency1Decimals,
}

export const poolKey: PoolKeyT = {
    currency0: deployment.pool.currency0,
    currency1: deployment.pool.currency1,
    fee: deployment.pool.fee,
    tickSpacing: deployment.pool.tickSpacing,
    hooks: deployment.hook,
}

// A 0x-prefixed 32-byte hex private key. Catches unset/placeholder values (e.g. "0x...") with a
// clear, named error rather than viem's cryptic "invalid private key, got string" deep in a call.
function requirePk(name: string, value: string | undefined): `0x${string}` {
    if (!value || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
        throw new Error(`${name} must be a 0x-prefixed 32-byte hex private key (got ${value ?? "unset"})`);
    }
    return value as `0x${string}`;
}

export function requireOperatorKeys() {
    return {
        operatorPk: requirePk("OPERATOR_PK", config.operatorPk),
        settlerCallerPk: requirePk("SETTLER_CALLER_PK", config.settlerCallerPk),
    };
}

// Shared read-only chain client. Both services use it for view calls (slot0, nonce bitmap, etc).
export const publicClient = createPublicClient({ transport: http(config.rpcUrl) });
