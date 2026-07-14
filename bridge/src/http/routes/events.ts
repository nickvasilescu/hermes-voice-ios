import { Router } from "express";
import type { Config } from "../../config.js";
import type { TaskEventBus } from "../../tasks/events.js";

export function eventsRouter(eventBus: TaskEventBus, config: Config): Router {
  const router = Router();

  router.get("/events", (req, res) => {
    const hermesSessionId = req.hermesSessionId;

    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "x-accel-buffering": "no",
    });
    res.flushHeaders?.();

    const unsubscribe = eventBus.subscribe(hermesSessionId, (event) => {
      res.write(`event: ${event.type}\ndata: ${JSON.stringify(event.task)}\n\n`);
    });

    const pingInterval = setInterval(() => {
      res.write(`event: ping\ndata: ${JSON.stringify({ ts: new Date().toISOString() })}\n\n`);
    }, config.ssePingMs);

    req.on("close", () => {
      clearInterval(pingInterval);
      unsubscribe();
    });
  });

  return router;
}
