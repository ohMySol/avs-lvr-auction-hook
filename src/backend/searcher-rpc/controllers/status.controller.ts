import type { Request, Response, NextFunction } from "express";
import { type Address, isAddress } from "viem";
import { ValidationError } from "../verify";

// Reports whether a user's intent (identified by user + nonce) has been filled on-chain.
// `filled` once the Settler has consumed the nonce; otherwise `pending` (queued or not yet settled).
// Minimal frontend-facing status endpoint; richer per-intent tracking can build on this later.
export const makeStatusController =
    (isNonceUsed: (user: Address, nonce: bigint) => Promise<boolean>) =>
    async (req: Request, res: Response, next: NextFunction): Promise<void> => {
        try {
            const user = String(req.query.user ?? "");
            const nonceRaw = String(req.query.nonce ?? "");
            if (!isAddress(user)) throw new ValidationError("query param 'user' must be an address");
            if (!/^\d+$/.test(nonceRaw)) throw new ValidationError("query param 'nonce' must be an integer");

            const filled = await isNonceUsed(user as Address, BigInt(nonceRaw));
            res.status(200).json({ ok: true, user, nonce: nonceRaw, status: filled ? "filled" : "pending" });
        } catch (err) {
            next(err);
        }
    };
