// Operator signing of the per-block winner tuple, matching what AuctionServiceManager.commitWinner
// verifies on-chain: each operator signs the EIP-191-prefixed keccak of the packed tuple, and a
// quorum of >= threshold unique signatures is required to commit.
import { keccak256, encodePacked, type Account, type Hex } from "viem";
import type { WinnerTupleT } from "../../shared/types";

// keccak256(abi.encodePacked(poolId, targetBlock, winner, bidAmount)).
// Packed types and order are (bytes32, uint256, address, uint256) — must byte-match the contract.
export function winnerHash(t: WinnerTupleT): Hex {
    return keccak256(
        encodePacked(
            ["bytes32", "uint256", "address", "uint256"],
            [t.poolId, t.targetBlock, t.winner, t.bidAmount],
        ),
    );
}

// Sign the winner hash. signMessage applies the EIP-191 prefix, mirroring the contract's
// toEthSignedMessageHash(...) before ecrecover.
export async function signWinnerTuple(account: Account, t: WinnerTupleT): Promise<Hex> {
    return account.signMessage!({ message: { raw: winnerHash(t) } });
}

// Gather signatures until the quorum threshold is met. Demo: local accounts signed in-process.
// Testnet (Milestone 5): replace with network calls to remote operator nodes — same shape.
export async function collectSignatures(
    operators: Account[],
    tuple: WinnerTupleT,
    threshold: number,
): Promise<Hex[]> {
    const sigs: Hex[] = [];
    for (const op of operators) {
        sigs.push(await signWinnerTuple(op, tuple));
        if (sigs.length >= threshold) break;
    }
    if (sigs.length < threshold) {
        throw new Error(`quorum not met: ${sigs.length}/${threshold}`);
    }
    return sigs;
}
