# Deployment

This repository is provider-neutral. Deploy the Node bridge anywhere that can
keep long-lived SSE connections open and make outbound HTTPS requests. Keep
host inventory, tunnel identifiers, secret-manager paths, and operator tokens
outside the public repository.

## Build artifact

```bash
cd bridge
npm ci
npm run typecheck
npm test
npm run build
NODE_ENV=production node dist/server.js
```

Run the process as an unprivileged service account. Build once, deploy an
immutable artifact, and retain a known-good rollback artifact.

## Required production configuration

| Variable | Classification | Notes |
|---|---|---|
| `NODE_ENV=production` | non-secret | Enables fail-closed production behavior. |
| `HOST` / `PORT` | non-secret | Bind loopback behind a proxy unless direct binding is intentional. |
| `OPENAI_API_KEY` | secret | Standard key; bridge only. Never send to iOS. |
| `OPENAI_REALTIME_MODEL` | non-secret | Defaults to `gpt-realtime-2.1`. |
| `BRIDGE_BOOTSTRAP_SECRET` | secret/test seam | Required by this scaffold in production; replace with real identity. |
| `HERMES_API_BASE_URL` | usually non-secret | Set with `HERMES_API_KEY` for the real provider. |
| `HERMES_API_KEY` | secret | Bridge-to-Hermes credential. |
| `BRIDGE_CORS_ALLOWLIST` | non-secret | Explicit origins; empty denies cross-origin production requests. |

Inject secrets at process start from the hosting platform or a secret manager.
Do not bake them into an image, repository file, mobile bundle, command-line
argument, or generated environment artifact that persists resolved values.

## Network edge

- Terminate TLS before any internet-facing request reaches the bridge.
- Preserve SSE streaming; disable response buffering for `/v1/events`.
- Set proxy trust only for the actual proxy topology, otherwise per-IP rate
  limits can be spoofed.
- Restrict the origin listener to loopback or a private network where possible.
- Apply request/body/time limits at both the proxy and application layers.
- Do not share a hostname/path router with unrelated services unless every
  route and rollback has been tested independently.

The iOS release build should point at this HTTPS origin through its ignored
`Config/Local.xcconfig` or your own release configuration. URLs are public
metadata; credentials are not build settings.

## Identity and persistence

The included static bootstrap secret is not sufficient for a multi-user public
service. Before launch:

1. Put user login, passkeys, managed-device identity, or attestation in front
   of `POST /v1/session`.
2. Bind each client session to the authenticated principal.
3. Replace in-memory sessions, tasks, idempotency, and rate-limit state with
   durable quota-enforced stores.
4. Define retention, deletion, audit, and revocation behavior.
5. Use a stable privacy-preserving safety identifier when minting Realtime
   client secrets. This bridge sends its opaque server-owned client scope as
   `OpenAI-Safety-Identifier`; a real identity layer should derive a stable
   non-PII identifier per user.

## Health and smoke checks

A release is not healthy merely because the process exists. Verify, without
printing credentials:

1. `GET /v1/health` succeeds through the public TLS endpoint.
2. An unauthenticated `POST /v1/session` is denied in production.
3. An authenticated bootstrap returns one client session token.
4. A harmless mock or dedicated test task reaches a terminal state.
5. Realtime client-secret minting succeeds and returns an `ek_` credential;
   validate its presence without logging its value.
6. SSE remains open and delivers a task update.

Keep smoke-test identities and tasks isolated from real users.

## Logging and monitoring

- Ship structured logs to access-controlled storage.
- Preserve the logger's recursive redaction and never log authorization
  headers, request credentials, tool arguments containing sensitive data, or
  full OpenAI client secrets.
- Alert on bootstrap failures, upstream Realtime failures, repeated session
  minting, task-provider failures, SSE churn, and memory/entry-limit pressure.
- Audit approvals with minimal necessary task metadata.

## Release gate

Before moving traffic:

```bash
make check
make ios-test
git diff --check
```

Run Gitleaks over the candidate and its Git history. Confirm the candidate is a
clean, reviewed commit, the rollback artifact is independently usable, and the
physical-device voice flow passes against the candidate endpoint.
