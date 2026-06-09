import { z } from "zod";
import type { SwapIntentT } from "../../../shared/types";

// 0x-prefixed hex of a fixed byte length (e.g. 20-byte address, 32-byte poolId).
const hexBytes = (bytes: number) =>
    z.string().regex(new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`), `expected ${bytes}-byte hex`);

// Any 0x-prefixed hex string of even length (signature length is checked on-chain).
const hex = z.string().regex(/^0x[0-9a-fA-F]*$/, "expected 0x-prefixed hex");

// A non-negative integer delivered as a decimal string, coerced to bigint.
// JSON has no bigint, so clients send these uint fields as strings.
const uintString = z
    .string()
    .regex(/^\d+$/, "expected a non-negative integer string")
    .transform((s) => BigInt(s));

// Wire shape of POST /intent. Validates every field at the boundary, then transforms the
// numeric strings into the bigint-typed SwapIntentT the rest of the backend works with.
export const intentSchema = z.object({
    user: hexBytes(20),
    poolId: hexBytes(32),
    zeroForOne: z.boolean(),
    amountIn: uintString,
    minAmountOut: uintString,
    nonce: uintString,
    deadline: uintString,
    signature: hex,
});

// Parse-and-validate an untrusted request body into a typed SwapIntentT.
// Throws ZodError on any malformed/missing field; the error middleware maps that to a 400.
export function parseIntentBody(body: unknown): SwapIntentT {
    return intentSchema.parse(body) as SwapIntentT;
}
