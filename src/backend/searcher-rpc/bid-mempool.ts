import type Redis from "ioredis";
import type { SignedBidT, BidSource } from "../../shared/types";

// One Redis list per pool for arb bids, separate from the intent queue.
const bidKey = (poolId: string) => `bids:${poolId.toLowerCase()}`;

// bigint fields (targetBlock, bidAmount) are encoded as decimal strings for JSON.
export function serializeBid(b: SignedBidT): string {
    return JSON.stringify({ ...b, targetBlock: b.targetBlock.toString(), bidAmount: b.bidAmount.toString() });
}

export function deserializeBid(raw: string): SignedBidT {
    const o = JSON.parse(raw);
    return { ...o, targetBlock: BigInt(o.targetBlock), bidAmount: BigInt(o.bidAmount) };
}

// Redis-backed bid queue: searcher-rpc RPUSHes validated bids; the operator atomically drains them
// each block to run the auction. Implements BidSource so the operator loop depends on the shape.
export class RedisBidQueue implements BidSource {
    constructor(private readonly redis: Redis, private readonly poolId: string) {}

    async addBid(bid: SignedBidT): Promise<void> {
        await this.redis.rpush(bidKey(this.poolId), serializeBid(bid));
    }

    // Atomic read-and-clear so each bid is auctioned in exactly one block.
    async drainBids(): Promise<SignedBidT[]> {
        const k = bidKey(this.poolId);
        const res = await this.redis.multi().lrange(k, 0, -1).del(k).exec();
        const items = (res?.[0]?.[1] as string[]) ?? [];
        return items.map(deserializeBid);
    }
}
