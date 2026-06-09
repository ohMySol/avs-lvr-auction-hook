import type { Address, Hex } from "viem";
import type { SwapIntentT } from "../../../shared/types";
import { validateIntent } from "../verify";

// Collaborators the service needs, injected so it stays unit-testable and free of transport concerns.
export interface IntentServiceDeps {
    settler: Address;
    chainId: number;
    expectedPoolId: Hex;
    // Tail of the queue the operator drains each block.
    add: (intent: SwapIntentT) => Promise<void>;
    // On-chain nonce-bitmap read.
    isNonceUsed: (user: Address, nonce: bigint) => Promise<boolean>;
}

// Application layer: validate an intent against live chain state, then enqueue it.
// Holds no HTTP knowledge — the controller adapts requests to this, and the loop drains the queue.
export class IntentService {
    constructor(private readonly deps: IntentServiceDeps) {}

    async submit(intent: SwapIntentT): Promise<void> {
        await validateIntent(intent, {
            settler: this.deps.settler,
            chainId: this.deps.chainId,
            expectedPoolId: this.deps.expectedPoolId,
            now: BigInt(Math.floor(Date.now() / 1000)),
            isNonceUsed: this.deps.isNonceUsed,
        });
        await this.deps.add(intent);
    }
}
