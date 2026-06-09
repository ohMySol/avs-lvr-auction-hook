// Searcher arb-bid intake and winner election.
// collectBids drains whatever the searcher-rpc queued for this block; with no bidders the queue is
// empty and the designated operator wins at bid 0 — every block still has a winner who can settle.
import type { Address } from "viem";
import type { BidSource } from "../../shared/types";

// A signed offer to pay for the exclusive right to make the arb swap this block.
export interface ArbBid {
    bidder: Address;
    bidAmount: bigint;
}

export interface AuctionInput {
    bids: ArbBid[];
    // Who settles when nobody bids; in the demo this is the local operator.
    designatedOperator: Address;
}

export interface AuctionOutcome {
    winner: Address;
    bidAmount: bigint;
}

// Drain the block's arb bids from the queue the searcher-rpc fills, mapping each signed bid to the
// (bidder, bidAmount) the auction needs.
export async function collectBids(source: BidSource): Promise<ArbBid[]> {
    const bids = await source.drainBids();
    return bids.map((b) => ({ bidder: b.bidder, bidAmount: b.bidAmount }));
}

// Elect the block winner: highest bid wins; with no bids the designated operator wins at bid 0.
// Decouples settlement duty from the arb auction, so every block always has someone who can settle.
export function runAuction(input: AuctionInput): AuctionOutcome {
    if (input.bids.length === 0) {
        return { winner: input.designatedOperator, bidAmount: 0n };
    }
    const best = input.bids.reduce((x, y) => (y.bidAmount > x.bidAmount ? y : x));
    return { winner: best.bidder, bidAmount: best.bidAmount };
}
