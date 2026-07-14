import { Router } from "express";
import type { ClientSessionStore } from "../../auth/clientSession.js";
import type { Config } from "../../config.js";
import type { Logger } from "../../logger.js";
import { requireBootstrapCredential } from "../middleware/bootstrapAuth.js";

/**
 * `POST /v1/session` — mints a client session token. This is the only
 * route in the whole API that a static shared secret ever gates (see
 * `requireBootstrapCredential`); everything else requires the token this
 * route returns. See docs/PROTOCOL.md §2 and docs/SECURITY.md.
 */
export function sessionRouter(config: Config, store: ClientSessionStore, logger: Logger): Router {
  const router = Router();

  router.post("/session", requireBootstrapCredential(config, logger), (_req, res) => {
    const minted = store.create();
    logger.info("session.minted", { hermesSessionId: minted.hermesSessionId, expiresAt: minted.expiresAt });
    res.status(201).json({
      sessionToken: minted.token,
      hermesSessionId: minted.hermesSessionId,
      expiresAt: minted.expiresAt,
    });
  });

  return router;
}
