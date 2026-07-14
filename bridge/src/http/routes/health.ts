import { Router } from "express";

export function healthRouter(): Router {
  const router = Router();
  router.get("/health", (_req, res) => {
    res.json({ ok: true, uptimeSeconds: Math.round(process.uptime()) });
  });
  return router;
}
