const SENSITIVE_KEYS = new Set(["authorization", "apikey", "value", "token", "password"]);

/**
 * Recursively masks values whose key name looks sensitive. `clientSecret`
 * itself is not masked wholesale (its `expiresAt` is useful in logs) —
 * only the leaf `value` field is. [IMPLEMENTED]
 */
export function redact(input: unknown): unknown {
  if (Array.isArray(input)) return input.map((item) => redact(item));
  if (input === null || typeof input !== "object") return input;

  const output: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    if (SENSITIVE_KEYS.has(key.toLowerCase())) {
      output[key] = "[REDACTED]";
    } else if (typeof value === "object" && value !== null) {
      output[key] = redact(value);
    } else {
      output[key] = value;
    }
  }
  return output;
}

export type LogLevel = "info" | "warn" | "error";

export interface Logger {
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
}

function log(level: LogLevel, event: string, fields?: Record<string, unknown>): void {
  const line = {
    level,
    event,
    ts: new Date().toISOString(),
    ...(fields ? (redact(fields) as Record<string, unknown>) : {}),
  };
  const serialized = JSON.stringify(line);
  if (level === "error") console.error(serialized);
  else if (level === "warn") console.warn(serialized);
  else console.log(serialized);
}

export const logger: Logger = {
  info: (event, fields) => log("info", event, fields),
  warn: (event, fields) => log("warn", event, fields),
  error: (event, fields) => log("error", event, fields),
};
