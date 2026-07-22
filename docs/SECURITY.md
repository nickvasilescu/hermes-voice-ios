# Security model

Hermes Voice keeps the mobile client narrow: it receives short-lived client
credentials and can invoke five typed task operations. It never receives the
standard OpenAI key or the Hermes provider key.

## Secret handling

- `OPENAI_API_KEY` remains on the bridge. The app receives only a short-lived
  Realtime client secret from `POST /v1/realtime/session`.
- `HERMES_API_KEY` remains on the bridge and is used only by the API Server
  provider.
- Client session tokens are returned once, stored by iOS in Keychain, and
  retained server-side only as SHA-256 hashes.
- `.env`, resolved secret-reference files, local xcconfigs, signing material,
  and common key formats are ignored. Local and CI checks reject obvious
  tracked credentials.
- Structured logs recursively redact authorization, API keys, tokens,
  passwords, and OpenAI client-secret fields.
- `BRIDGE_MOCK_OPENAI=1` emits an unmistakable `mock_ek_` development value and
  must not be enabled in production.
- The bridge sets `OpenAI-Safety-Identifier` while minting each client secret,
  using the opaque server-owned client scope rather than PII.

Do not store resolved production values in this repository. Use a hosting
platform or secret manager, least-privilege service identity, and in-memory
injection. If a credential is committed, revoke it before rewriting history.

## Authentication and authorization

`POST /v1/session` is the bootstrap route:

1. In production, this scaffold requires `BRIDGE_BOOTSTRAP_SECRET`.
2. The bridge generates an opaque bearer token and `hermesSessionId`.
3. Only the token hash and session binding are retained.
4. Every task, SSE, and Realtime-credential request requires that token.
5. Middleware resolves ownership from the token; the client cannot choose or
   override a session ID.

The static bootstrap value is an operator/test seam, not a mobile-app secret or
a production identity system. Replace or front it with authenticated login,
passkeys, managed-device identity, or attestation before serving real users.

If a bridge restart forgets a still-valid Keychain token, the client performs
one bounded recovery: invalidate, bootstrap again, and retry once. A second
`401` stops rather than looping.

## Realtime and Hermes boundary

- Realtime receives exactly five typed tools and no raw terminal, filesystem,
  HTTP, MCP, or Hermes protocol access.
- Function calls are deduplicated by OpenAI `call_id` before side effects.
- `hermesSessionId` is an authenticated ownership scope and never
  model-controlled.
- Each independent task receives a bridge-generated `hermesThreadId`.
  Follow-ups reuse only that task's thread.
- Approval resolution requires the pending `approvalId` to match the task.
- Provider startup failures move tasks to a failed terminal state.

These boundaries limit blast radius; they do not make arbitrary Hermes tools
safe. A deployment must still authorize individual actions and defend against
prompt injection in untrusted task content.

## Input and memory bounds

- Zod schemas limit instruction, context, request-ID, follow-up, cancellation,
  approval, and note shapes.
- Client sessions, tasks, idempotency records, and rate-limit buckets use
  bounded in-memory stores with TTL eviction.
- Express enforces a global JSON-body limit.

The in-memory implementation is development-grade. Production needs durable
storage, quotas, per-identity accounting, and explicit retention/deletion.

## Transport

- Mobile and browser clients should use WebRTC with short-lived client
  credentials; standard keys are server-only.
- Configure `BRIDGE_CORS_ALLOWLIST` explicitly. Empty is permissive only in
  development and denies cross-origin production requests.
- The Node process serves HTTP. Terminate TLS at a trusted reverse proxy or
  load balancer.
- Trust forwarded addresses only from the known proxy topology.
- Preserve SSE streaming and bound connection/resource usage.

## Data at rest

- The bridge task store is in memory and loses tasks on restart.
- The scaffold does not intentionally write task instructions, results, or
  approvals to disk.
- iOS persists client-session and bootstrap material only in Keychain.

Production must define storage encryption, retention, deletion, backup, audit,
and device-revocation behavior.

## Production requirements

Before internet exposure to real users:

1. Add real user/device identity and session revocation.
2. Use TLS end to end and a stable privacy-preserving safety identifier.
3. Replace in-memory state and rate limiting with durable shared services.
4. Add minimal, redacted approval and security audit logs.
5. Threat-model prompt injection, stolen devices, replay, token theft, abusive
   audio sessions, and compromised Hermes providers.
6. Run static analysis, bridge tests, iOS tests, dependency review, secret
   scanning, and physical-device audio acceptance.
7. Follow the private disclosure process in the root `SECURITY.md`.
