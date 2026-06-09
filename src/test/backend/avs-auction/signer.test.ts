import { describe, it, expect } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverMessageAddress } from "viem";
import { winnerHash, signWinnerTuple, collectSignatures } from "../../../backend/avs-auction/signer";
import type { WinnerTupleT } from "../../../shared/types";

const a = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const b = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

const tuple: WinnerTupleT = {
    poolId: ("0x" + "11".repeat(32)) as `0x${string}`,
    targetBlock: 1n,
    winner: a.address,
    bidAmount: 0n,
};

describe("winnerHash", () => {
    it("is a deterministic bytes32", () => {
        expect(winnerHash(tuple)).toMatch(/^0x[0-9a-f]{64}$/);
        expect(winnerHash(tuple)).toBe(winnerHash({ ...tuple }));
    });
});

describe("signWinnerTuple", () => {
    it("signs the EIP-191-prefixed hash so the operator recovers", async () => {
        const sig = await signWinnerTuple(a, tuple);
        const signer = await recoverMessageAddress({ message: { raw: winnerHash(tuple) }, signature: sig });
        expect(signer.toLowerCase()).toBe(a.address.toLowerCase());
    });
});

describe("collectSignatures", () => {
    it("collects exactly threshold signatures", async () => {
        expect((await collectSignatures([a, b], tuple, 2)).length).toBe(2);
    });

    it("throws below quorum", async () => {
        await expect(collectSignatures([a], tuple, 2)).rejects.toThrow(/quorum/i);
    });
});
