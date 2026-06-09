import { describe, it, expect } from "vitest";
import { priceToSqrtX96 } from "../../../backend/avs-auction/cex-price";
import { buildArbParams } from "../../../backend/avs-auction/pool-price";
import { runAuction } from "../../../backend/avs-auction/bid-collector";

describe("priceToSqrtX96", () => {
    const Q96 = 2n ** 96n;

    it("maps price 1.0 (18/18) to exactly Q96 and is monotonic in price", () => {
        expect(priceToSqrtX96(1)).toBe(Q96);
        expect(priceToSqrtX96(4) > priceToSqrtX96(1)).toBe(true);
        expect(priceToSqrtX96(4)).toBe(2n * Q96); // sqrt(4) = 2
    });

    it("folds in the 6/18 decimal gap for a USDC/WETH-style pair", () => {
        // price = currency1 per currency0 = WETH per USDC = 1/2000; decimals0=6, decimals1=18.
        // price_raw = (1/2000) * 10^12 = 5e8; sqrtP = sqrt(5e8) * 2^96 ≈ 1.77e33.
        const sqrtP = priceToSqrtX96(1 / 2000, 6, 18);
        // Tight band around the analytic value (22360.68 * Q96).
        const lo = 22360n * Q96;
        const hi = 22361n * Q96;
        expect(sqrtP > lo && sqrtP < hi).toBe(true);
    });
});

describe("buildArbParams", () => {
    const target = priceToSqrtX96(1.0);

    it("sells token0 (zeroForOne) when the pool price is above target", () => {
        const arb = buildArbParams(priceToSqrtX96(1.1), target, 10n ** 24n);
        expect(arb.zeroForOne).toBe(true);
    });

    it("buys token0 (!zeroForOne) when the pool price is below target", () => {
        const arb = buildArbParams(priceToSqrtX96(0.9), target, 10n ** 24n);
        expect(arb.zeroForOne).toBe(false);
    });

    it("caps as exact-in and stops at the target price", () => {
        const arb = buildArbParams(priceToSqrtX96(1.1), target, 10n ** 24n);
        expect(arb.amountSpecified).toBe(-(10n ** 24n));
        expect(arb.sqrtPriceLimitX96).toBe(target);
    });
});

describe("runAuction", () => {
    const op = "0x00000000000000000000000000000000000000a1" as const;
    const b1 = "0x00000000000000000000000000000000000000b1" as const;
    const b2 = "0x00000000000000000000000000000000000000b2" as const;

    it("picks the highest bid", () => {
        const outcome = runAuction({
            bids: [
                { bidder: b2, bidAmount: 9n },
                { bidder: b1, bidAmount: 5n },
            ],
            designatedOperator: op,
        });
        expect(outcome).toEqual({ winner: b2, bidAmount: 9n });
    });

    it("falls back to the designated operator with bid 0 when there are no bids", () => {
        expect(runAuction({ bids: [], designatedOperator: op })).toEqual({ winner: op, bidAmount: 0n });
    });
});
