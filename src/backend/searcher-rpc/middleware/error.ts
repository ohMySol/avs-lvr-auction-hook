import type { Request, Response, NextFunction } from "express";
import { ZodError } from "zod";
import { ValidationError } from "../verify";

// Centralised error handler. Keeps responses uniform and never leaks stack traces to clients.
// Client-input failures (schema or business-rule) are 400; anything else is a generic 500.
// The unused `next` is required for Express to recognise this as an error handler (4-arg arity).
export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
    if (err instanceof ZodError) {
        res.status(400).json({ ok: false, error: "invalid request body", issues: err.issues });
        return;
    }
    if (err instanceof ValidationError) {
        res.status(400).json({ ok: false, error: err.message });
        return;
    }
    // Unexpected (e.g. Redis/RPC failure): log server-side, return an opaque 500.
    console.error("searcher-rpc unhandled error:", err);
    res.status(500).json({ ok: false, error: "internal error" });
}
