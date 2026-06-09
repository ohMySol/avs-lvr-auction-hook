import type { Request, Response } from "express";

// Liveness/readiness probe for docker-compose healthchecks and uptime monitoring.
export const healthController = (_req: Request, res: Response): void => {
    res.status(200).json({ ok: true, service: "searcher-rpc" });
};
