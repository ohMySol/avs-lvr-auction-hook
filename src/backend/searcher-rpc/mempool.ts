import type Redis from "ioredis";
import type { SwapIntentT, IntentSource } from "../../shared/types";

// One Redis list per pool. Lower-cased so the producer and consumer never disagree on the key.
const listKey = (poolId: string) => `intents:${poolId.toLowerCase()}`;

// JSON cannot represent bigint, so the four uint fields are encoded as decimal strings.
export function serializeIntent(intent: SwapIntentT): string {
    return JSON.stringify({
        ...intent,
        amountIn: intent.amountIn.toString(),
        minAmountOut: intent.minAmountOut.toString(),
        nonce: intent.nonce.toString(),
        deadline: intent.deadline.toString(),
    });
}

// Inverse of serializeIntent: the decimal strings are parsed back into bigint.
export function deserializeIntent(raw: string): SwapIntentT {
    const o = JSON.parse(raw);
    return {
        ...o,
        amountIn: BigInt(o.amountIn),
        minAmountOut: BigInt(o.minAmountOut),
        nonce: BigInt(o.nonce),
        deadline: BigInt(o.deadline),
    };
}

// Redis-backed queue decoupling the two services: searcher-rpc RPUSHes validated intents,
// avs-auction atomically drains them once per block. Implements IntentSource so the operator
// loop depends on the structural type, never on this concrete class.
export class RedisMempool implements IntentSource {
    constructor(private readonly redis: Redis, private readonly poolId: string) {}

    // Append a validated intent to the tail of the pool's queue.
    async add(intent: SwapIntentT): Promise<void> {
        await this.redis.rpush(listKey(this.poolId), serializeIntent(intent));
    }

    // Atomically read-and-clear the whole queue so an intent is handed to exactly one block.
    // LRANGE + DEL run in a single MULTI; a concurrent add either lands fully before or after.
    async drain(): Promise<SwapIntentT[]> {
        const k = listKey(this.poolId);
        const res = await this.redis.multi().lrange(k, 0, -1).del(k).exec();
        const items = (res?.[0]?.[1] as string[]) ?? [];
        return items.map(deserializeIntent);
    }
}
