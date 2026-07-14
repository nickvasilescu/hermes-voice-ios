import { randomBytes, randomUUID, createHash } from "node:crypto";
import { TTLMap } from "../util/ttlMap.js";

export interface ClientSessionRecord {
  hermesSessionId: string;
  expiresAt: string;
}

export interface MintedClientSession {
  token: string;
  hermesSessionId: string;
  expiresAt: string;
}

export interface ClientSessionStoreOptions {
  ttlMs: number;
  maxEntries: number;
  clock?: () => number;
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/**
 * Server-minted, server-held client sessions — the replacement for a
 * client-supplied `X-Hermes-Session-Id` header and a global bridge bearer
 * token (see docs/SECURITY.md). [IMPLEMENTED]
 *
 * `hermesSessionId` is chosen by the server, never accepted from a client.
 * Only a SHA-256 hash of each opaque bearer token is retained — the
 * plaintext token is returned exactly once, at mint time, and is
 * unrecoverable from server state after that (matches how the bridge
 * treats the OpenAI API key: mint/pass through, never store/log
 * plaintext).
 */
export class ClientSessionStore {
  private readonly ttlMs: number;
  private readonly records: TTLMap<string, ClientSessionRecord>;

  constructor(options: ClientSessionStoreOptions) {
    this.ttlMs = options.ttlMs;
    this.records = new TTLMap({ ttlMs: options.ttlMs, maxEntries: options.maxEntries, clock: options.clock });
  }

  create(): MintedClientSession {
    const token = `st_${randomBytes(32).toString("base64url")}`;
    const hermesSessionId = `hs_${randomUUID()}`;
    const expiresAt = new Date(Date.now() + this.ttlMs).toISOString();

    this.records.set(hashToken(token), { hermesSessionId, expiresAt });
    return { token, hermesSessionId, expiresAt };
  }

  validate(token: string): ClientSessionRecord | undefined {
    return this.records.peek(hashToken(token));
  }

  /**
   * Test-only introspection. `ClientSessionRecord` has no token field at
   * all — there is nothing here for a plaintext token to hide in.
   */
  debugDumpForTests(): ClientSessionRecord[] {
    return [...this.records.values()];
  }
}
