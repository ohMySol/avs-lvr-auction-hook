import { describe, it, expect } from "vitest";
import { serializeIntent, deserializeIntent } from "../../../backend/searcher-rpc/mempool";
import type { SwapIntentT } from "../../../shared/types";

describe("intent (de)serialization", () => {
    it("round-trips bigints through JSON without loss", () => {
        const intent: SwapIntentT = {
            user: "0x0000000000000000000000000000000000000001",
            poolId: ("0x" + "11".repeat(32)) as `0x${string}`,
            zeroForOne: true,
            amountIn: 10n ** 18n,
            minAmountOut: 5n,
            nonce: 42n,
            deadline: 1_730_000_000n,
            signature: "0xabcd",
        };
        expect(deserializeIntent(serializeIntent(intent))).toEqual(intent);
    });

    it("preserves bigint type (not string) after round-trip", () => {
        const intent: SwapIntentT = {
            user: "0x0000000000000000000000000000000000000001",
            poolId: ("0x" + "11".repeat(32)) as `0x${string}`,
            zeroForOne: false,
            amountIn: 1n,
            minAmountOut: 0n,
            nonce: 0n,
            deadline: 1n,
            signature: "0x",
        };
        const out = deserializeIntent(serializeIntent(intent));
        expect(typeof out.amountIn).toBe("bigint");
        expect(typeof out.nonce).toBe("bigint");
    });
});
