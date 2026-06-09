import { describe, it, expect } from "vitest";
import { parseIntentBody } from "../../../backend/searcher-rpc/schemas/intent.schema";

const valid = {
    user: "0x0000000000000000000000000000000000000001",
    poolId: "0x" + "11".repeat(32),
    zeroForOne: true,
    amountIn: "1000000000000000000",
    minAmountOut: "1",
    nonce: "7",
    deadline: "9999999999",
    signature: "0x" + "ab".repeat(65),
};

describe("parseIntentBody", () => {
    it("parses a valid body and coerces numeric strings to bigint", () => {
        const intent = parseIntentBody(valid);
        expect(intent.amountIn).toBe(10n ** 18n);
        expect(typeof intent.nonce).toBe("bigint");
        expect(intent.user).toBe(valid.user);
    });

    it("rejects a malformed address", () => {
        expect(() => parseIntentBody({ ...valid, user: "0xnotanaddress" })).toThrow();
    });

    it("rejects a non-numeric amount string", () => {
        expect(() => parseIntentBody({ ...valid, amountIn: "abc" })).toThrow();
    });

    it("rejects a missing field", () => {
        const { signature, ...partial } = valid;
        expect(() => parseIntentBody(partial)).toThrow();
    });

    it("rejects a negative amount", () => {
        expect(() => parseIntentBody({ ...valid, amountIn: "-1" })).toThrow();
    });
});
