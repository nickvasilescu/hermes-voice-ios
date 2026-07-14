import express, { type Express, type NextFunction, type Request, type Response } from "express";
import { ClientSessionStore } from "./auth/clientSession.js";
import type { Config } from "./config.js";
import { HermesProviderError, type HermesProvider } from "./hermes/provider.js";
import { MockHermesProvider } from "./hermes/mockProvider.js";
import { asyncHandler } from "./http/asyncHandler.js";
import { buildCors } from "./http/middleware/cors.js";
import { requireClientSession } from "./http/middleware/clientSession.js";
import { buildRateLimiter } from "./http/middleware/rateLimit.js";
import { eventsRouter } from "./http/routes/events.js";
import { healthRouter } from "./http/routes/health.js";
import { realtimeSessionRouter } from "./http/routes/realtimeSession.js";
import { sessionRouter } from "./http/routes/session.js";
import { tasksRouter } from "./http/routes/tasks.js";
import { logger as defaultLogger, type Logger } from "./logger.js";
import { TaskEventBus } from "./tasks/events.js";
import { TaskService, TaskServiceError } from "./tasks/service.js";
import { TaskStore } from "./tasks/store.js";

export interface AppDependencies {
  config: Config;
  hermesProvider?: HermesProvider;
  fetchImpl?: typeof fetch;
  logger?: Logger;
  clientSessionStore?: ClientSessionStore;
}

export interface BuiltApp {
  app: Express;
  taskService: TaskService;
  taskEventBus: TaskEventBus;
  clientSessionStore: ClientSessionStore;
}

/**
 * Assembles the Express app from injectable dependencies so tests can spin
 * up a real HTTP server against a mock provider / fake fetch without
 * touching the network. [IMPLEMENTED]
 *
 * Auth: `POST /v1/session` is the only route gated by a static secret
 * (`requireBootstrapCredential`, inside `sessionRouter`); every other
 * `/v1/*` route requires the client session token that route mints
 * (`requireClientSession`). There is no global bridge bearer secret. See
 * docs/SECURITY.md.
 */
export function createApp(deps: AppDependencies): BuiltApp {
  const { config } = deps;
  const logger = deps.logger ?? defaultLogger;
  const fetchImpl = deps.fetchImpl ?? fetch;

  const store = new TaskStore({
    ttlMs: config.taskTtlMs,
    maxEntries: config.taskMaxEntries,
    idempotencyTtlMs: config.idempotencyTtlMs,
    idempotencyMaxEntries: config.idempotencyMaxEntries,
  });
  const taskEventBus = new TaskEventBus();
  const hermesProvider = deps.hermesProvider ?? new MockHermesProvider();
  const taskService = new TaskService(store, hermesProvider, taskEventBus, (err) => {
    logger.error("hermes_provider.async_error", { detail: err instanceof Error ? err.message : String(err) });
  });
  const clientSessionStore =
    deps.clientSessionStore ??
    new ClientSessionStore({ ttlMs: config.clientSessionTtlMs, maxEntries: config.clientSessionMaxEntries });

  const app = express();
  app.disable("x-powered-by");
  app.use(buildCors(config));
  app.use(express.json({ limit: "1mb" }));

  app.use("/v1", healthRouter());

  const rateLimited = express.Router();
  rateLimited.use(buildRateLimiter(config));
  rateLimited.use(sessionRouter(config, clientSessionStore, logger));

  const authed = express.Router();
  authed.use(requireClientSession(clientSessionStore));
  authed.use(realtimeSessionRouter(config, fetchImpl, logger));
  authed.use(tasksRouter(taskService));
  authed.use(eventsRouter(taskEventBus, config));
  rateLimited.use(authed);

  app.use("/v1", rateLimited);

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: "not_found" });
  });

  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof TaskServiceError) {
      res.status(err.status).json({ error: err.code, detail: err.message });
      return;
    }
    if (err instanceof HermesProviderError) {
      res.status(502).json({ error: err.code, detail: err.message });
      return;
    }
    logger.error("http.unhandled_error", { detail: err instanceof Error ? err.stack ?? err.message : String(err) });
    res.status(500).json({ error: "internal_error" });
  });

  return { app, taskService, taskEventBus, clientSessionStore };
}

// keep asyncHandler import used across route modules that import from here in tests indirectly
export { asyncHandler };
