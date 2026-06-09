import { describe, it, expect } from "vitest";
import { parseBidBody } from "../../../backend/searcher-rpc/schemas/bid.schema";

const valid = {
    poolId: "0x" + "11".repeat(32),
    targetBlock: "100",
    bidder: "0x0000000000000000000000000000000000000001",
    bidAmount: "1000000000000000000",
    signature: "0x" + "ab".repeat(65),
};

describe("parseBidBody", () => {
    it("parses a valid bid and coerces numeric strings to bigint", () => {
        const bid = parseBidBody(valid);
        expect(bid.bidAmount).toBe(10n ** 18n);
        expect(typeof bid.targetBlock).toBe("bigint");
        expect(bid.bidder).toBe(valid.bidder);
    });

    it("rejects a malformed bidder address", () => {
        expect(() => parseBidBody({ ...valid, bidder: "0xnope" })).toThrow();
    });

    it("rejects a non-numeric bid amount", () => {
        expect(() => parseBidBody({ ...valid, bidAmount: "lots" })).toThrow();
    });

    it("rejects a missing field", () => {
        const { signature, ...partial } = valid;
        expect(() => parseBidBody(partial)).toThrow();
    });
});
