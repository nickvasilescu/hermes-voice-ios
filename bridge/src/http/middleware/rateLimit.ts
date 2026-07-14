import type { NextFunction, Request, Response } from "express";
import type { Config } from "../../config.js";
import { TTLMap } from "../../util/ttlMap.js";

interface Bucket {
  count: number;
  resetAt: number;
}

/**
 * Fixed-window per-IP limiter, in-memory and bounded. [IMPLEMENTED] as a
 * dev-grade limiter: it resets on process restart and does not coordinate
 * across multiple instances. Bounded via `TTLMap` — at most
 * `rateLimitMaxEntries` distinct IPs are tracked at once (oldest evicted
 * first) and a bucket's TTL matches the rate-limit window itself, so
 * traffic from many distinct/spoofed IPs can't grow this without limit.
 * See docs/SECURITY.md for what a production limiter would need
 * (Redis-backed, sliding window, real `trust proxy` configuration).
 */
export function buildRateLimiter(config: Config) {
  const buckets = new TTLMap<string, Bucket>({
    ttlMs: config.rateLimitWindowMs,
    maxEntries: config.rateLimitMaxEntries,
  });

  return (req: Request, res: Response, next: NextFunction) => {
    const key = req.ip ?? "unknown";
    const now = Date.now();
    let bucket = buckets.peek(key);

    if (!bucket) {
      bucket = { count: 0, resetAt: now + config.rateLimitWindowMs };
      buckets.set(key, bucket);
    }

    bucket.count += 1;
    if (bucket.count > config.rateLimitMax) {
      res.status(429).json({ error: "rate_limited", retryAfterMs: bucket.resetAt - now });
      return;
    }
    next();
  };
}
