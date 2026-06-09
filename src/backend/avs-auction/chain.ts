// Chain writes for the operator: commit the AVS winner, then settle the block.
// Reads live in pool-price.ts; this module holds the two state-changing transactions.
import { createWalletClient, http, type Hex, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { config, poolKey, publicClient, requireOperatorKeys } from "../../shared/config";
import { auctionServiceManagerAbi, settlerAbi } from "../../shared/abi";
import type { SwapIntentT, SwapParamsT } from "../../shared/types";

// A wallet client bound to a private key. chain is null because we target a bare RPC (Anvil/fork)
// and pass an explicit chainId via the transport rather than a viem chain object.
function walletFor(pk: `0x${string}`) {
    return createWalletClient({ account: privateKeyToAccount(pk), transport: http(config.rpcUrl) });
}

// Commit the per-block auction winner to AuctionServiceManager with the operator quorum's
// signatures. Signed by the operator key. Waits for the receipt so the loop knows it landed.
export async function commitWinner(
    poolId: Hex,
    targetBlock: bigint,
    winner: Address,
    bidAmount: bigint,
    signatures: Hex[],
): Promise<Hex> {
    const { operatorPk } = requireOperatorKeys();
    const hash = await walletFor(operatorPk).writeContract({
        address: config.asm,
        abi: auctionServiceManagerAbi,
        functionName: "commitWinner",
        args: [poolId, targetBlock, winner, bidAmount, signatures],
        chain: null,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    return hash;
}

// Settle the block as `callerPk`, which MUST equal the committed winner (the Settler enforces it).
// Step 1 arb rebalance (skipped if arb.amountSpecified == 0) then Step 2 intent fills, atomically.
export async function settleAs(
    callerPk: `0x${string}`,
    arb: SwapParamsT,
    intents: SwapIntentT[],
): Promise<Hex> {
    const hash = await walletFor(callerPk).writeContract({
        address: config.settler,
        abi: settlerAbi,
        functionName: "settle",
        args: [poolKey, arb, intents],
        chain: null,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    return hash;
}

// Convenience: settle with the configured settler-caller key (the no-bid path, winner == operator).
export async function settle(arb: SwapParamsT, intents: SwapIntentT[]): Promise<Hex> {
    const { settlerCallerPk } = requireOperatorKeys();
    return settleAs(settlerCallerPk, arb, intents);
}
