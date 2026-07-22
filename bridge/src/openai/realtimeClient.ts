import { randomUUID } from "node:crypto";
import type { Config } from "../config.js";

export interface RealtimeSessionResult {
  sessionId: string;
  model: string;
  clientSecret: { value: string; expiresAt: string };
  createdAt: string;
  expiresInSeconds: number;
}

export class RealtimeUpstreamError extends Error {
  constructor(
    message: string,
    public readonly detail?: string
  ) {
    super(message);
    this.name = "RealtimeUpstreamError";
  }
}

/**
 * Mints an OpenAI Realtime ephemeral client credential. [IMPLEMENTED] as a
 * real call against the documented `client_secrets` endpoint. Parsing remains
 * deliberately defensive because upstream response fields can evolve.
 */
export async function mintRealtimeSession(
  config: Config,
  fetchImpl: typeof fetch,
  voice: string | undefined,
  safetyIdentifier: string
): Promise<RealtimeSessionResult> {
  if (!config.openaiApiKey) {
    throw new Error("openai_api_key_missing");
  }

  const requestBody = {
    session: {
      type: "realtime",
      model: config.realtimeModel,
      audio: { output: { voice: voice ?? "marin" } },
    },
  };

  let response: Response;
  try {
    response = await fetchImpl(config.openaiRealtimeUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        Authorization: `Bearer ${config.openaiApiKey}`,
        "OpenAI-Safety-Identifier": safetyIdentifier,
      },
      body: JSON.stringify(requestBody),
    });
  } catch (err) {
    throw new RealtimeUpstreamError(
      "upstream_error",
      err instanceof Error ? err.message : String(err)
    );
  }

  if (!response.ok) {
    const detail = await response.text().catch(() => undefined);
    throw new RealtimeUpstreamError("upstream_error", detail);
  }

  const parsed = (await response.json()) as Record<string, unknown>;
  return mapResponse(parsed, config.realtimeModel);
}

function mapResponse(parsed: Record<string, unknown>, model: string): RealtimeSessionResult {
  const value =
    typeof parsed.value === "string"
      ? parsed.value
      : typeof (parsed.client_secret as Record<string, unknown> | undefined)?.value === "string"
        ? ((parsed.client_secret as Record<string, unknown>).value as string)
        : undefined;
  if (!value) throw new RealtimeUpstreamError("upstream_error", "response missing client secret value");

  const expiresAtRaw = parsed.expires_at ?? (parsed.client_secret as Record<string, unknown> | undefined)?.expires_at;
  let expiresAtMs: number;
  if (typeof expiresAtRaw === "number" && Number.isFinite(expiresAtRaw)) {
    expiresAtMs = expiresAtRaw * 1000;
  } else if (typeof expiresAtRaw === "string" && expiresAtRaw.trim()) {
    expiresAtMs = Date.parse(expiresAtRaw);
  } else {
    throw new RealtimeUpstreamError("upstream_error", "response missing client secret expiry");
  }
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now()) {
    throw new RealtimeUpstreamError("upstream_error", "response has invalid or expired client secret expiry");
  }
  const expiresAt = new Date(expiresAtMs).toISOString();

  const sessionId = (parsed.session as Record<string, unknown> | undefined)?.id;
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    throw new RealtimeUpstreamError("upstream_error", "response missing session id");
  }

  const createdAt = new Date().toISOString();
  const expiresInSeconds = Math.max(1, Math.floor((expiresAtMs - Date.now()) / 1000));

  return {
    sessionId,
    model,
    clientSecret: { value, expiresAt },
    createdAt,
    expiresInSeconds,
  };
}

/** Dev-only, obviously-fake credential so the rest of the stack is exercisable without an OpenAI account. */
export function mockRealtimeSession(config: Config): RealtimeSessionResult {
  const now = Date.now();
  return {
    sessionId: `sess_mock_${randomUUID()}`,
    model: config.realtimeModel,
    clientSecret: { value: `mock_ek_${randomUUID()}`, expiresAt: new Date(now + 3600_000).toISOString() },
    createdAt: new Date(now).toISOString(),
    expiresInSeconds: 3600,
  };
}
