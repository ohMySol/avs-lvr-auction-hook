import { z } from "zod";
import type { SignedBidT } from "../../../shared/types";

const hexBytes = (bytes: number) =>
    z.string().regex(new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`), `expected ${bytes}-byte hex`);
const hex = z.string().regex(/^0x[0-9a-fA-F]*$/, "expected 0x-prefixed hex");
const uintString = z
    .string()
    .regex(/^\d+$/, "expected a non-negative integer string")
    .transform((s) => BigInt(s));

// Wire shape of POST /bid: a searcher's signed offer for the block's arb right.
export const bidSchema = z.object({
    poolId: hexBytes(32),
    targetBlock: uintString,
    bidder: hexBytes(20),
    bidAmount: uintString,
    signature: hex,
});

// Parse + validate an untrusted body into a typed SignedBidT (throws ZodError -> 400 on failure).
export function parseBidBody(body: unknown): SignedBidT {
    return bidSchema.parse(body) as SignedBidT;
}
