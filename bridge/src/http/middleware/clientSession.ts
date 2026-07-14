import type { NextFunction, Request, Response } from "express";
import type { ClientSessionStore } from "../../auth/clientSession.js";

declare module "express-serve-static-core" {
  interface Request {
    hermesSessionId: string;
  }
}

/**
 * Requires a valid, minted client session token on every task/events/
 * realtime-session route. Replaces the old client-supplied
 * `X-Hermes-Session-Id` header and the old global bridge bearer token —
 * see docs/SECURITY.md. `hermesSessionId` is resolved server-side from the
 * token; it is never accepted verbatim from the client. [IMPLEMENTED]
 */
export function requireClientSession(store: ClientSessionStore) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const header = req.header("authorization") ?? "";
    const [scheme, token] = header.split(" ");
    if (scheme !== "Bearer" || !token) {
      res.status(401).json({ error: "missing_session_token" });
      return;
    }

    const record = store.validate(token);
    if (!record) {
      res.status(401).json({ error: "invalid_session" });
      return;
    }

    req.hermesSessionId = record.hermesSessionId;
    next();
  };
}
