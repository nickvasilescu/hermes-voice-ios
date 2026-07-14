import corsMiddleware from "cors";
import type { Config } from "../../config.js";

/**
 * Allowlist-based CORS. With an empty allowlist: permissive (reflects any
 * origin) outside production, closed in production. Never wildcards in
 * production. See docs/SECURITY.md.
 */
export function buildCors(config: Config) {
  return corsMiddleware({
    origin(origin, callback) {
      if (!origin) return callback(null, true); // non-browser callers send no Origin header
      if (config.corsAllowlist.includes(origin)) return callback(null, true);
      if (config.corsAllowlist.length === 0 && config.nodeEnv !== "production") {
        return callback(null, true);
      }
      return callback(null, false);
    },
    credentials: false,
  });
}
