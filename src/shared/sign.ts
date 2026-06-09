import { keccak256, encodePacked, type Account, type Address, type Hex } from "viem";
import { SwapIntentT } from "./types";

// The schema for the intent signature. It mirrors the fields on the SwapIntent Solidity struct.
export const INTENT_TYPES = {
    SwapIntent: [
        { name: "user", type: "address" }, 
        { name: "poolId", type: "bytes32" },
        { name: "zeroForOne", type: "bool" }, 
        { name: "amountIn", type: "uint128" },
        { name: "minAmountOut", type: "uint128" }, 
        { name: "nonce", type: "uint64" },
        { name: "deadline", type: "uint64" },
  ],
} as const;

// The EIP-712 domain separator. This should match the domain separator used in the Settler contract.
// Binds the signature to a specific contract and chain. This prevents signature replay — a signature for 
// the Settler on Ethereum can't be replayed on Arbitrum and can't be used against a different contract
export function intentDomain(settler: Address, chainId: number) {
    return {
        name: "EigenAuction Settler",
        version: "1", 
        chainId, 
        verifyingContract: settler 
    } as const;
}

// Function takes a viem Account, the Settler address, chain ID and the unsigned intent.
// `signTypedData` encodes the domain + types + message into a deterministic hash (EIP-712) -->
// signs that hash with the accounts private key --> returns the signature hex.
export async function signIntent(
    account: Account,
    settler: Address,
    chainId: number,
    intent: Omit<SwapIntentT, "signature">,
): Promise<Hex> {
    return account.signTypedData!({
        domain: intentDomain(settler, chainId),
        types: INTENT_TYPES,
        primaryType: "SwapIntent",
        message: intent
    });
}

// The bid commitment hash: keccak256(abi.encodePacked(poolId, targetBlock, bidAmount)).
// Same packing the AuctionServiceManager checks in challengeWinner, so a signed bid is a valid
// fraud-proof if a lower winner was committed.
export function bidHash(poolId: Hex, targetBlock: bigint, bidAmount: bigint): Hex {
    return keccak256(encodePacked(["bytes32", "uint256", "uint256"], [poolId, targetBlock, bidAmount]));
}

// Sign a searcher bid. signMessage applies the EIP-191 prefix, matching the contract's
// toEthSignedMessageHash(...) before ecrecover.
export async function signBid(
    account: Account,
    poolId: Hex,
    targetBlock: bigint,
    bidAmount: bigint,
): Promise<Hex> {
    return account.signMessage!({ message: { raw: bidHash(poolId, targetBlock, bidAmount) } });
}
