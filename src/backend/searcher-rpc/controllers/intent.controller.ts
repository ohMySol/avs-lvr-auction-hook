import type { Request, Response, NextFunction } from "express";
import { parseIntentBody } from "../schemas/intent.schema";
import type { IntentService } from "../services/intent.service";

// Thin HTTP adapter: parse+validate the body, delegate to the service, shape the response.
// All errors are forwarded to the central error middleware via next(), never handled here.
export const makeIntentController = (service: IntentService) =>
    async (req: Request, res: Response, next: NextFunction): Promise<void> => {
        try {
            const intent = parseIntentBody(req.body);
            await service.submit(intent);
            // 202: accepted into the mempool; settlement happens later, off this request.
            res.status(202).json({ ok: true });
        } catch (err) {
            next(err);
        }
    };
