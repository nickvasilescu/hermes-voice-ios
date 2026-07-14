import { timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, Response } from "express";
import type { Config } from "../../config.js";
import type { Logger } from "../../logger.js";

function safeEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

/**
 * Gates `POST /v1/session` — the only route allowed to mint a client
 * session token (see docs/SECURITY.md). This is deliberately the *only*
 * place a static shared secret is ever checked; every other route requires
 * a minted, hashed, TTL-bound client session token instead. [IMPLEMENTED]
 *
 * - `BRIDGE_BOOTSTRAP_SECRET` set: require `Authorization: Bearer <secret>`,
 *   constant-time compared, on every environment.
 * - Unset + `NODE_ENV=production`: fail closed. A production deployment
 *   with no bootstrap secret configured is a misconfiguration, not an
 *   "open" mode — refuse to mint sessions rather than mint them for anyone.
 * - Unset + any other `NODE_ENV`: allow, but log a warning on every mint so
 *   this can't silently go unnoticed in a shared/staging environment.
 */
export function requireBootstrapCredential(config: Config, logger: Logger) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (config.bootstrapSecret) {
      const header = req.header("authorization") ?? "";
      const [scheme, token] = header.split(" ");
      if (scheme !== "Bearer" || !token || !safeEqual(token, config.bootstrapSecret)) {
        res.status(401).json({ error: "unauthorized" });
        return;
      }
      next();
      return;
    }

    if (config.nodeEnv === "production") {
      logger.error("session.bootstrap_secret_missing_in_production", {});
      res.status(500).json({ error: "bootstrap_secret_missing" });
      return;
    }

    logger.warn("session.open_bootstrap", {
      detail: "BRIDGE_BOOTSTRAP_SECRET is not set — minting a client session with no credential check. Dev only.",
    });
    next();
  };
}
