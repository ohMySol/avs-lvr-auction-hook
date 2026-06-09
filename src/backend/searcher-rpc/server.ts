import express from "express";
import Redis from "ioredis";
import type { Address } from "viem";
import { config, poolKey, publicClient } from "../../shared/config";
import { getPoolId } from "../../shared/poolId";
import { settlerAbi } from "../../shared/abi";
import { RedisMempool } from "./mempool";
import { RedisBidQueue } from "./bid-mempool";
import { IntentService } from "./services/intent.service";
import { BidService } from "./services/bid.service";
import { buildRouter } from "./routes";
import { errorHandler } from "./middleware/error";

// Public ingress for the auction: searchers/users POST signed intents here; valid ones are
// pushed to Redis for the operator to drain each block. Composition root — wires infra
// (Redis, RPC) into the service, mounts the router, then starts listening.
async function main(): Promise<void> {
    const redis = new Redis(config.redisUrl);
    const poolId = getPoolId(poolKey);
    const mempool = new RedisMempool(redis, poolId);
    const bidQueue = new RedisBidQueue(redis, poolId);

    // Live nonce-bitmap read against the Settler, injected into the service + status endpoint.
    const isNonceUsed = (user: Address, nonce: bigint): Promise<boolean> =>
        publicClient.readContract({
            address: config.settler,
            abi: settlerAbi,
            functionName: "isNonceUsed",
            args: [user, nonce],
        });

    const intentService = new IntentService({
        settler: config.settler,
        chainId: config.chainId,
        expectedPoolId: poolId,
        add: (intent) => mempool.add(intent),
        isNonceUsed,
    });

    const bidService = new BidService({
        expectedPoolId: poolId,
        addBid: (bid) => bidQueue.addBid(bid),
    });

    const app = express();
    app.use(express.json());
    app.use(buildRouter({ intentService, bidService, isNonceUsed }));
    app.use(errorHandler);

    const server = app.listen(config.intentPort, () =>
        console.log(`searcher-rpc listening on :${config.intentPort} (pool ${poolId})`),
    );

    // Close Redis and the HTTP listener cleanly on container stop so no intent is half-written.
    const shutdown = async () => {
        server.close();
        await redis.quit();
        process.exit(0);
    };
    process.on("SIGTERM", shutdown);
    process.on("SIGINT", shutdown);
}

main().catch((err) => {
    console.error("searcher-rpc failed to start:", err);
    process.exit(1);
});
