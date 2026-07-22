import { Router } from "express";
import type { Config } from "../../config.js";
import type { Logger } from "../../logger.js";
import { mintRealtimeSession, mockRealtimeSession, RealtimeUpstreamError } from "../../openai/realtimeClient.js";
import { asyncHandler } from "../asyncHandler.js";
import { realtimeSessionSchema } from "../validation.js";

export function realtimeSessionRouter(config: Config, fetchImpl: typeof fetch, logger: Logger): Router {
  const router = Router();

  router.post(
    "/realtime/session",
    asyncHandler(async (req, res) => {
      const parsed = realtimeSessionSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "validation_error", detail: parsed.error.message });
        return;
      }

      if (!config.openaiApiKey) {
        if (config.mockOpenAI) {
          logger.warn("realtime_session.mock_mode", { hermesSessionId: req.hermesSessionId });
          res.status(200).json(mockRealtimeSession(config));
          return;
        }
        res.status(500).json({ error: "openai_api_key_missing" });
        return;
      }

      try {
        // This server-generated opaque scope is stable for the client session
        // and contains no user PII. OpenAI binds it to the ephemeral secret.
        const result = await mintRealtimeSession(config, fetchImpl, parsed.data.voice, req.hermesSessionId);
        logger.info("realtime_session.minted", {
          hermesSessionId: req.hermesSessionId,
          sessionId: result.sessionId,
          expiresAt: result.clientSecret.expiresAt,
        });
        res.status(200).json(result);
      } catch (err) {
        if (err instanceof RealtimeUpstreamError) {
          logger.error("realtime_session.upstream_error", { detail: err.detail });
          res.status(502).json({ error: "upstream_error", detail: err.detail });
          return;
        }
        throw err;
      }
    })
  );

  return router;
}
