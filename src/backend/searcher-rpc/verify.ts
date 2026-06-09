import { recoverTypedDataAddress, recoverMessageAddress, type Address, type Hex } from "viem";
import type { SwapIntentT, SignedBidT } from "../../shared/types";
import { INTENT_TYPES, intentDomain, bidHash } from "../../shared/sign";

// Thrown when an intent is well-formed JSON but fails a business rule (wrong pool, expired,
// bad signature, used nonce). Distinct from infra errors so the API maps it to 400, not 500.
export class ValidationError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "ValidationError";
    }
}

// Recover the address that produced an intent's EIP-712 signature.
// Re-derives the exact (domain, types, message) the Settler verifies on-chain, so a signature
// that recovers to `intent.user` here is byte-identical to one the contract accepts.
export async function recoverIntentSigner(
    settler: Address,
    chainId: number,
    intent: SwapIntentT,
): Promise<Address> {
    const { signature, ...message } = intent;
    return recoverTypedDataAddress({
        domain: intentDomain(settler, chainId),
        types: INTENT_TYPES,
        primaryType: "SwapIntent",
        message,
        signature,
    });
}

// Everything validateIntent needs that comes from outside the intent itself.
export interface ValidationCtx {
    settler: Address;
    chainId: number;
    // The pool this RPC serves; intents for any other pool are rejected up front.
    expectedPoolId: Hex;
    // Current unix time (seconds) used for the deadline check.
    now: bigint;
    // On-chain nonce-bitmap read; injected so the pure validator stays testable.
    isNonceUsed: (user: Address, nonce: bigint) => Promise<boolean>;
}

// Reject any intent the winning operator could not validly settle, mirroring the Settler's own
// checks so we never queue an intent that would revert on-chain.
// Cheapest, signature-free checks run first; the ECDSA recovery and the on-chain nonce read last.
// Throws on the first failure with a stable, client-safe message.
export async function validateIntent(intent: SwapIntentT, ctx: ValidationCtx): Promise<void> {
    if (intent.poolId.toLowerCase() !== ctx.expectedPoolId.toLowerCase()) {
        throw new ValidationError("intent targets the wrong pool");
    }
    if (intent.deadline < ctx.now) {
        throw new ValidationError("intent has expired");
    }
    if (intent.amountIn === 0n) {
        throw new ValidationError("intent has zero amountIn");
    }

    const signer = await recoverIntentSigner(ctx.settler, ctx.chainId, intent);
    if (signer.toLowerCase() !== intent.user.toLowerCase()) {
        throw new ValidationError("invalid signature: signer does not match user");
    }

    if (await ctx.isNonceUsed(intent.user, intent.nonce)) {
        throw new ValidationError("nonce already used");
    }
}

// Recover the address that signed a bid, from the EIP-191-prefixed bid hash.
export async function recoverBidSigner(bid: SignedBidT): Promise<Address> {
    return recoverMessageAddress({
        message: { raw: bidHash(bid.poolId, bid.targetBlock, bid.bidAmount) },
        signature: bid.signature,
    });
}

// Reject a searcher bid that is malformed or for the wrong pool, or whose signature does not match
// the claimed bidder. Throws ValidationError (mapped to 400) on the first failure.
export async function validateBid(bid: SignedBidT, expectedPoolId: Hex): Promise<void> {
    if (bid.poolId.toLowerCase() !== expectedPoolId.toLowerCase()) {
        throw new ValidationError("bid targets the wrong pool");
    }
    if (bid.bidAmount === 0n) {
        throw new ValidationError("bid amount is zero");
    }
    const signer = await recoverBidSigner(bid);
    if (signer.toLowerCase() !== bid.bidder.toLowerCase()) {
        throw new ValidationError("invalid bid signature: signer does not match bidder");
    }
}
