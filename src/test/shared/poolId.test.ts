import { describe, it, expect } from "vitest";
import { getPoolId } from "../../shared/poolId";

describe("getPoolId Tests", () => {
    it("getPoolId should return bytes32 hash of the pool key", () => {
        const id = getPoolId({
            currency0: "0x0000000000000000000000000000000000000001",
            currency1: "0x0000000000000000000000000000000000000002",
            fee: 3000,
            tickSpacing: 60,
            hooks: "0x0000000000000000000000000000000000000003"
        });

        expect(id).toMatch(/^0x[0-9a-f]{64}$/);
    })
})