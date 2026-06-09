import type { Request, Response, NextFunction } from "express";
import { parseBidBody } from "../schemas/bid.schema";
import type { BidService } from "../services/bid.service";

// Thin HTTP adapter for POST /bid: parse+validate the body, delegate to the service, shape response.
export const makeBidController =
    (service: BidService) =>
    async (req: Request, res: Response, next: NextFunction): Promise<void> => {
        try {
            const bid = parseBidBody(req.body);
            await service.submit(bid);
            res.status(202).json({ ok: true });
        } catch (err) {
            next(err);
        }
    };
