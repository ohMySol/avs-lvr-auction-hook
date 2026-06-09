// AVS operator node (entrypoint: start-operator).
// Each block: read pool vs external price, size the arb, elect a winner, commit it with the
// operator quorum's signatures, drain user intents from Redis, and settle the block.
import "dotenv/config";
import Redis from "ioredis";
import { privateKeyToAccount } from "viem/accounts";
import { config, poolKey, publicClient, requireOperatorKeys } from "../../shared/config";
import { getPoolId } from "../../shared/poolId";
import { RedisMempool } from "../searcher-rpc/mempool";
import { RedisBidQueue } from "../searcher-rpc/bid-mempool";
import type { IntentSource, BidSource } from "../../shared/types";
import { externalPrice, priceToSqrtX96 } from "./cex-price";
import { getSlot0, buildArbParams } from "./pool-price";
import { collectBids, runAuction } from "./bid-collector";
import { collectSignatures } from "./signer";
import { commitWinner, settle } from "./chain";

// Large exact-in cap; the pool swaps until it hits the target price and stops, so the cap only
// needs to exceed the liquidity required to close the gap.
const CAP_AMOUNT_IN = 10n ** 21n;

// Single-operator demo quorum. Testnet raises this and aggregates remote signatures (Milestone 5).
const QUORUM_THRESHOLD = 1;

// Under Anvil automine each tx mines its own block, so commitWinner consumes one block before
// settle. settle therefore executes at (latest + 2), which is the block its winner must be
// committed for. Landing settle in a precise block on a live chain needs top-of-block submission
// (Milestone 5); this offset is the demo/fork assumption.
const SETTLE_BLOCK_OFFSET = 2n;

// Run one auction round end-to-end. Exported so the fork demo can drive a single block directly.
export async function runBlock(
    mempool: IntentSource,
    bidSource: BidSource,
    capAmountIn: bigint = CAP_AMOUNT_IN,
): Promise<void> {
    const poolId = getPoolId(poolKey);
    const { operatorPk } = requireOperatorKeys();
    const operator = privateKeyToAccount(operatorPk);

    // Size the arb from the current pool price vs the external target.
    const { sqrtPriceX96 } = await getSlot0(poolId);
    const target = priceToSqrtX96(await externalPrice(), config.decimals0, config.decimals1);
    let arb = buildArbParams(sqrtPriceX96, target, capAmountIn);
    // Already at the target: no arb to make, so skip Step 1 by zeroing the swap.
    if (sqrtPriceX96 === target) arb = { ...arb, amountSpecified: 0n };

    // Drain user intents now so we know whether the block has anything to settle.
    const intents = await mempool.drain();

    // Settler reverts if both the arb is skipped and there are no intents — don't commit a winner
    // for a block we won't settle.
    if (arb.amountSpecified === 0n && intents.length === 0) return;

    // Elect the winner from the block's bids (empty queue → designated operator at bid 0).
    const outcome = runAuction({ bids: await collectBids(bidSource), designatedOperator: operator.address });

    const targetBlock = (await publicClient.getBlockNumber()) + SETTLE_BLOCK_OFFSET;
    const signatures = await collectSignatures(
        [operator],
        { poolId, targetBlock, winner: outcome.winner, bidAmount: outcome.bidAmount },
        QUORUM_THRESHOLD,
    );

    await commitWinner(poolId, targetBlock, outcome.winner, outcome.bidAmount, signatures);
    await settle(arb, intents);
}

// Long-running operator: react to each new block. Errors in one round are logged and swallowed so
// the loop survives transient RPC/settle failures.
async function main(): Promise<void> {
    const redis = new Redis(config.redisUrl);
    const poolId = getPoolId(poolKey);
    const mempool = new RedisMempool(redis, poolId);
    const bidSource = new RedisBidQueue(redis, poolId);

    console.log("avs-auction operator running");
    const unwatch = publicClient.watchBlockNumber({
        onBlockNumber: async () => {
            try {
                await runBlock(mempool, bidSource);
            } catch (err) {
                console.error("runBlock error:", err);
            }
        },
    });

    const shutdown = async () => {
        unwatch();
        await redis.quit();
        process.exit(0);
    };
    process.on("SIGTERM", shutdown);
    process.on("SIGINT", shutdown);
}

// Only start the long-running loop when executed directly, not when imported by the fork demo.
if (require.main === module) {
    main().catch((err) => {
        console.error("avs-auction failed to start:", err);
        process.exit(1);
    });
}
