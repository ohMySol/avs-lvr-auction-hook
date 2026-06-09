import type { Hex } from "viem";
import type { SignedBidT } from "../../../shared/types";
import { validateBid } from "../verify";

// Collaborators injected so the service stays unit-testable and transport-free.
export interface BidServiceDeps {
    expectedPoolId: Hex;
    // Tail of the bid queue the operator drains each block.
    addBid: (bid: SignedBidT) => Promise<void>;
}

// Application layer for arb bids: validate the signed bid, then enqueue it for the auction.
export class BidService {
    constructor(private readonly deps: BidServiceDeps) {}

    async submit(bid: SignedBidT): Promise<void> {
        await validateBid(bid, this.deps.expectedPoolId);
        await this.deps.addBid(bid);
    }
}
