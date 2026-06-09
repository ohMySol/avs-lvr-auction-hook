import { describe, it, expect } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverMessageAddress } from "viem";
import { bidHash, signBid } from "../../shared/sign";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const poolId = ("0x" + "11".repeat(32)) as `0x${string}`;

describe("bidHash", () => {
    it("is a deterministic bytes32 over (poolId, targetBlock, bidAmount)", () => {
        expect(bidHash(poolId, 5n, 10n ** 18n)).toMatch(/^0x[0-9a-f]{64}$/);
        expect(bidHash(poolId, 5n, 10n ** 18n)).toBe(bidHash(poolId, 5n, 10n ** 18n));
        expect(bidHash(poolId, 5n, 1n)).not.toBe(bidHash(poolId, 5n, 2n));
    });
});

describe("signBid", () => {
    it("signs the EIP-191-prefixed bid hash so the bidder recovers", async () => {
        const sig = await signBid(account, poolId, 5n, 10n ** 18n);
        const signer = await recoverMessageAddress({
            message: { raw: bidHash(poolId, 5n, 10n ** 18n) },
            signature: sig,
        });
        expect(signer.toLowerCase()).toBe(account.address.toLowerCase());
    });
});
