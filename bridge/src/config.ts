export interface Config {
  nodeEnv: string;
  port: number;
  openaiApiKey: string | undefined;
  openaiRealtimeUrl: string;
  realtimeModel: string;
  mockOpenAI: boolean;
  corsAllowlist: string[];
  rateLimitMax: number;
  rateLimitWindowMs: number;
  rateLimitMaxEntries: number;
  ssePingMs: number;

  /**
   * Shared secret required to call POST /v1/session (mint a client
   * session). Unset means "no bootstrap secret configured" — see
   * loadConfig's doc comment for what that means per nodeEnv.
   */
  bootstrapSecret: string | undefined;
  clientSessionTtlMs: number;
  clientSessionMaxEntries: number;

  taskTtlMs: number;
  taskMaxEntries: number;
  idempotencyTtlMs: number;
  idempotencyMaxEntries: number;
}

function parseIntStrict(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || !Number.isInteger(parsed)) {
    throw new Error(`Invalid integer for ${name}: ${JSON.stringify(value)}`);
  }
  return parsed;
}

function parseBoolFlag(value: string | undefined): boolean {
  return value === "1" || value?.toLowerCase() === "true";
}

const HOUR_MS = 60 * 60 * 1000;

/**
 * Pure function over an env-like object so it is trivially testable without
 * touching real process.env. [IMPLEMENTED]
 *
 * Auth model (see docs/SECURITY.md): there is no global bridge bearer
 * secret anymore. `BRIDGE_BOOTSTRAP_SECRET`, if set, gates who may call
 * `POST /v1/session` to mint a per-client session token; every other
 * `/v1/*` route requires that minted token, never the bootstrap secret
 * itself. If `BRIDGE_BOOTSTRAP_SECRET` is unset: in `NODE_ENV=production`
 * the bootstrap route fails closed (500) rather than silently allowing
 * anyone to mint a session; outside production it's open (dev
 * convenience), and every open bootstrap mint is logged loudly so this
 * can't accidentally go unnoticed in a shared dev deployment.
 */
export function loadConfig(env: Record<string, string | undefined>): Config {
  return {
    nodeEnv: env.NODE_ENV ?? "development",
    port: parseIntStrict(env.PORT, 8787, "PORT"),
    openaiApiKey: env.OPENAI_API_KEY,
    openaiRealtimeUrl: env.OPENAI_REALTIME_URL ?? "https://api.openai.com/v1/realtime/client_secrets",
    realtimeModel: env.OPENAI_REALTIME_MODEL ?? "gpt-realtime-2.1",
    mockOpenAI: parseBoolFlag(env.BRIDGE_MOCK_OPENAI),
    corsAllowlist: (env.BRIDGE_CORS_ALLOWLIST ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0),
    rateLimitMax: parseIntStrict(env.BRIDGE_RATE_LIMIT_MAX, 60, "BRIDGE_RATE_LIMIT_MAX"),
    rateLimitWindowMs: parseIntStrict(env.BRIDGE_RATE_LIMIT_WINDOW_MS, 60_000, "BRIDGE_RATE_LIMIT_WINDOW_MS"),
    rateLimitMaxEntries: parseIntStrict(env.BRIDGE_RATE_LIMIT_MAX_ENTRIES, 5000, "BRIDGE_RATE_LIMIT_MAX_ENTRIES"),
    ssePingMs: parseIntStrict(env.BRIDGE_SSE_PING_MS, 15_000, "BRIDGE_SSE_PING_MS"),

    bootstrapSecret: env.BRIDGE_BOOTSTRAP_SECRET,
    clientSessionTtlMs: parseIntStrict(env.BRIDGE_SESSION_TTL_MS, 24 * HOUR_MS, "BRIDGE_SESSION_TTL_MS"),
    clientSessionMaxEntries: parseIntStrict(env.BRIDGE_SESSION_MAX_ENTRIES, 10_000, "BRIDGE_SESSION_MAX_ENTRIES"),

    taskTtlMs: parseIntStrict(env.BRIDGE_TASK_TTL_MS, 24 * HOUR_MS, "BRIDGE_TASK_TTL_MS"),
    taskMaxEntries: parseIntStrict(env.BRIDGE_TASK_MAX_ENTRIES, 5000, "BRIDGE_TASK_MAX_ENTRIES"),
    idempotencyTtlMs: parseIntStrict(env.BRIDGE_IDEMPOTENCY_TTL_MS, 24 * HOUR_MS, "BRIDGE_IDEMPOTENCY_TTL_MS"),
    idempotencyMaxEntries: parseIntStrict(env.BRIDGE_IDEMPOTENCY_MAX_ENTRIES, 5000, "BRIDGE_IDEMPOTENCY_MAX_ENTRIES"),
  };
}
