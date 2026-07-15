# Security

Candid status: this is an MVP scaffold. The protections below are implemented, but a real multi-user deployment still needs an identity provider, durable storage, TLS termination, and operational monitoring.

## Secret handling

- `OPENAI_API_KEY` remains on the bridge. The iOS app receives only a short-lived OpenAI Realtime client credential from `POST /v1/realtime/session`.
- No bridge-wide bearer token is compiled into the app. `Info.plist` and both `.xcconfig` files contain no authentication credential.
- `POST /v1/session` returns an opaque client-session token once. iOS stores it in Keychain through `KeychainSessionStore`, never `UserDefaults`, `Info.plist`, or an xcconfig.
- The bridge stores only the SHA-256 hash of each client-session token.
- `.env` is ignored, while the bootstrap script and CI reject a tracked `.env`.
- Structured logs recursively redact authorization, API keys, tokens, passwords, and OpenAI client-secret values.
- `BRIDGE_MOCK_OPENAI=1` emits an unmistakable `mock_ek_` development credential and must not be enabled in production.
- Dewey's production wrapper resolves `op://` references in memory with
  `op run`; `bridge/.env.refs` contains references and non-secret settings,
  never resolved values. The bridge listens on loopback and is owned by
  Supervisor; Cloudflare remains the only intended public ingress.

## Authentication and session authorization

`POST /v1/session` is the client-session bootstrap route:

1. In production, it requires `BRIDGE_BOOTSTRAP_SECRET`.
2. The bridge generates both an opaque bearer token and a `hermesSessionId`.
3. Only the token hash and its session binding are retained server-side.
4. Every task, SSE, and Realtime-credential request requires the minted bearer token.
5. Middleware resolves `hermesSessionId` from the server-side binding. The client cannot choose, forge, or override another session ID.

If a bridge restart forgets an otherwise unexpired Keychain token, protected
requests recover once: the client invalidates that token, bootstraps a fresh
session with the operator credential, and retries once. A second `401` never
loops. A bootstrap `401` returns to the credential prompt.

The static bootstrap secret is not a mobile-app credential. Do not bundle it in iOS. For a real deployment, replace or front the bootstrap seam with authenticated login, passkeys, Sign in with Apple, managed-device identity, or attestation. An open bootstrap endpoint is permitted only in explicit non-production development mode.

## Input and memory bounds

- Zod schemas impose length and shape limits on instructions, context, request IDs, follow-ups, cancellation reasons, approval IDs, and notes.
- Client sessions, tasks, idempotency records, and rate-limit buckets use bounded in-memory storage with TTL/eviction rather than unbounded maps.
- Express retains a global JSON-body ceiling as a second line of defense.

These controls reduce accidental or hostile memory growth, but the in-memory implementation remains development-grade. Production should use a durable datastore with quotas and per-identity accounting.

## Transport

- Configure `BRIDGE_CORS_ALLOWLIST` explicitly. An empty allowlist is permissive only outside production; production denies cross-origin access by default.
- The bridge serves plain HTTP. Terminate TLS at a correctly configured reverse proxy or load balancer before any internet-facing deployment.
- Do not trust arbitrary proxy forwarding headers. Configure Express `trust proxy` only for the actual trusted proxy topology.
- OpenAI WebRTC signaling uses the current `POST /v1/realtime/calls` path. The account API key is never used by the mobile client.

## Rate limiting

The bridge includes a bounded, per-IP, fixed-window limiter. It is suitable for local development and a single-process demo, not distributed production. Production needs a shared limiter, authenticated-user quotas, and carefully configured proxy address handling.

## Data at rest

- The bridge task store is in memory and bounded. Restarting the bridge drops tasks and in-flight state.
- No task instruction, result, or approval detail is written to disk by this scaffold.
- The iOS client persists only its client-session material in Keychain.

A production Hermes provider and durable queue should become the source of truth for task state, with explicit retention and deletion policies.

## Realtime and Hermes trust boundary

- Realtime receives exactly five narrow, typed tools. It receives no raw terminal, filesystem, HTTP, MCP, or Hermes protocol access.
- Function calls are deduplicated by OpenAI `call_id` before side effects execute.
- `hermesSessionId` is not model-controlled and is not accepted from the iOS request. It is derived from the authenticated client session.
- Approval requests require the pending `approvalId` to match the task before the bridge resolves an action.
- Hermes-provider startup failures move tasks to a failed terminal state rather than leaving them queued indefinitely.

## Remaining production requirements

Before exposing this system to real users:

1. Put authenticated user or device identity in front of `POST /v1/session`.
2. Use TLS everywhere and rotate/revoke client sessions.
3. Replace memory stores with durable, quota-enforced infrastructure.
4. Add audit logging for approvals and sensitive Hermes actions without logging secrets or unnecessary prompt content.
5. Run iOS static analysis, `xcodebuild test`, strict Swift concurrency checks, and physical-device testing.
6. Threat-model prompt injection, stolen devices, replay, token theft, abusive audio sessions, and compromised Hermes providers.
7. Replace this section with an actual security contact and disclosure policy.
