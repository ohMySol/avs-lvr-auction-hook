import { Router } from "express";
import { type Address } from "viem";
import { healthController } from "../controllers/health.controller";
import { makeIntentController } from "../controllers/intent.controller";
import { makeBidController } from "../controllers/bid.controller";
import { makeStatusController } from "../controllers/status.controller";
import type { IntentService } from "../services/intent.service";
import type { BidService } from "../services/bid.service";

// Wires HTTP routes to their controllers. New endpoints slot in here without touching the bootstrap.
export function buildRouter(deps: {
    intentService: IntentService;
    bidService: BidService;
    isNonceUsed: (user: Address, nonce: bigint) => Promise<boolean>;
}): Router {
    const router = Router();

    router.get("/health", healthController);
    router.post("/intent", makeIntentController(deps.intentService));
    router.post("/bid", makeBidController(deps.bidService));
    router.get("/status", makeStatusController(deps.isNonceUsed));

    return router;
}
