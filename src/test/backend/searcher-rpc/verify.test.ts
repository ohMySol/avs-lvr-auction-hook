import { describe, it, expect } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import type { Address } from "viem";
import { signIntent } from "../../../shared/sign";
import { recoverIntentSigner, validateIntent } from "../../../backend/searcher-rpc/verify";
import type { SwapIntentT } from "../../../shared/types";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const settler = "0x0000000000000000000000000000000000000aaa" as Address;
const chainId = 31337;
const poolId = ("0x" + "11".repeat(32)) as `0x${string}`;

const base = {
    user: account.address,
    poolId,
    zeroForOne: true,
    amountIn: 10n ** 18n,
    minAmountOut: 1n,
    nonce: 7n,
    deadline: 9_999_999_999n,
};

async function signedIntent(): Promise<SwapIntentT> {
    const signature = await signIntent(account, settler, chainId, base);
    return { ...base, signature };
}

const ctxWith = (over: Partial<Parameters<typeof validateIntent>[1]> = {}) => ({
    settler,
    chainId,
    expectedPoolId: poolId,
    now: 1_000_000_000n,
    isNonceUsed: async () => false,
    ...over,
});

describe("recoverIntentSigner", () => {
    it("recovers the signing account", async () => {
        const intent = await signedIntent();
        const signer = await recoverIntentSigner(settler, chainId, intent);
        expect(signer.toLowerCase()).toBe(account.address.toLowerCase());
    });
});

describe("validateIntent", () => {
    it("accepts a well-formed, correctly-signed intent", async () => {
        await expect(validateIntent(await signedIntent(), ctxWith())).resolves.toBeUndefined();
    });

    it("rejects a wrong pool", async () => {
        const intent = await signedIntent();
        await expect(
            validateIntent(intent, ctxWith({ expectedPoolId: ("0x" + "22".repeat(32)) as `0x${string}` })),
        ).rejects.toThrow(/pool/i);
    });

    it("rejects an expired intent", async () => {
        const intent = await signedIntent();
        await expect(validateIntent(intent, ctxWith({ now: 10_000_000_000n }))).rejects.toThrow(/expire/i);
    });

    it("rejects zero amountIn", async () => {
        const signature = await signIntent(account, settler, chainId, { ...base, amountIn: 0n });
        await expect(validateIntent({ ...base, amountIn: 0n, signature }, ctxWith())).rejects.toThrow(/amount/i);
    });

    it("rejects a signature from someone other than user", async () => {
        const intent = await signedIntent();
        const forged = { ...intent, user: "0x000000000000000000000000000000000000dead" as Address };
        await expect(validateIntent(forged, ctxWith())).rejects.toThrow(/signature/i);
    });

    it("rejects an already-used nonce", async () => {
        const intent = await signedIntent();
        await expect(validateIntent(intent, ctxWith({ isNonceUsed: async () => true }))).rejects.toThrow(/nonce/i);
    });
});
