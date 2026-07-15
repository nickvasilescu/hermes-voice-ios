# PROTOCOL

This is the single source of truth for the contract between the **Hermes Voice
iOS app**, the **bridge backend**, **OpenAI Realtime** (`gpt-realtime-2.1`,
WebRTC transport) and **Hermes** (the durable task/memory/tool-execution
system). Both `bridge/` and `ios/HermesVoice` are implemented against this
document. If code and this document disagree, that is a bug — in either the
code or the doc.

Status legend used throughout: **[IMPLEMENTED]** — real, tested code in this
repo. **[SCAFFOLDED]** — types/interfaces/UI exist, but the concrete
integration (a real Hermes backend, a real WebRTC binary) is intentionally
out of scope for this MVP. **[MOCKED]** — a fake-but-honest local
implementation stands in (e.g. `MockHermesProvider`).

---

## 1. Actors and responsibilities

```
┌──────────────────┐        WebRTC (audio + datachannel)      ┌───────────────────────┐
│                   │ ◄────────────────────────────────────►  │  OpenAI Realtime API   │
│   iOS app         │                                          │  gpt-realtime-2.1      │
│   (HermesVoice)   │        HTTPS (REST + SSE)                └───────────────────────┘
│                   │ ────────────────────────────────────►   ┌───────────────────────┐
└──────────────────┘ ◄────────────────────────────────────    │  bridge/ (Node 22 TS)  │
                                                                │                        │
                                                                │  - mints OpenAI        │
                                                                │    ephemeral sessions  │
                                                                │  - owns task store     │
                                                                │  - fans out SSE events │
                                                                └───────────┬───────────┘
                                                                            │ HermesProvider
                                                                            ▼
                                                                ┌───────────────────────┐
                                                                │  Hermes                │
                                                                │  MockHermesProvider or │
                                                                │  ApiServerHermesProvider│
                                                                └───────────────────────┘
```

- **Realtime owns**: speech-to-text/text-to-speech, voice activity detection,
  turn-taking, barge-in, and narrating Hermes progress back to the user. It
  never talks to Hermes directly — it only ever calls the five tools below,
  which the iOS app executes against the bridge.
- **Hermes owns**: durable task execution, memory, and side-effecting tools
  (email, calendars, code, whatever the deployment wires up). Hermes tasks
  can outlive a single Realtime WebRTC session, an app backgrounding, or a
  phone restart, because they are keyed by `hermesSessionId`, not by the
  ephemeral OpenAI `session_id`.
- **bridge/ owns**: the narrow waist between the two. It never proxies audio;
  it mints short-lived OpenAI credentials, and it exposes a small REST+SSE
  surface for task lifecycle so the iOS app doesn't have to talk to Hermes'
  real protocol directly.

---

## 2. Identifiers

| Id | Owner | Lifetime | Purpose |
|---|---|---|---|
| `hermesSessionId` | bridge, generated when `POST /v1/session` mints a client session | Client-session TTL; survives Realtime rotation and app restarts while the Keychain token remains valid | Server-side scope for tasks and SSE. The client cannot choose or override it. |
| `sessionToken` | bridge, returned once by `POST /v1/session`; only its SHA-256 hash is retained server-side | Client-session TTL | Authenticates every protected request and resolves the bound `hermesSessionId` server-side. Stored only in iOS Keychain. |
| OpenAI Realtime `session_id` | OpenAI, minted by `POST /v1/realtime/session` | ≤ 60 minutes (this system rotates at 55 min, see §6) | Scopes the WebRTC/voice connection only. |
| `taskId` | bridge, format `task_<uuid v4>` | Until the client stops polling/listening or the dev store is restarted | Identifies one Hermes job. |
| `approvalId` | bridge/Hermes provider, format `appr_<uuid v4>` | Until resolved | Identifies one pending approval gate on a task. |
| `clientRequestId` | iOS app, caller-chosen string | One create call | Idempotency key for `delegate_to_hermes`, so a Realtime tool-call retry (e.g. after a flaky network blip) doesn't spawn a duplicate task. |

---

## 3. The five tools (Realtime function-calling surface)

These are the **only** tools registered on the OpenAI Realtime session via
`session.update`. Realtime is deliberately given no other capability — no
filesystem, no raw HTTP, no direct Hermes protocol. `hermesSessionId` is
**never** accepted from the model or client. The bridge resolves it from the
authenticated client-session token, so the model cannot forge or guess
another session's id.

### 3.1 `delegate_to_hermes`
```json
{
  "name": "delegate_to_hermes",
  "description": "Hand a durable task off to Hermes. Returns immediately with a task id; Hermes works asynchronously and reports progress/completion via task status updates that the app narrates back to you.",
  "parameters": {
    "type": "object",
    "properties": {
      "instruction": { "type": "string", "description": "What Hermes should do, in natural language." },
      "context": { "type": "object", "description": "Optional structured context (e.g. extracted entities, prior task ids to reference)." }
    },
    "required": ["instruction"]
  }
}
```
→ bridge: `POST /v1/tasks` → `{ taskId, status: "queued" }`

### 3.2 `get_hermes_task_status`
```json
{
  "name": "get_hermes_task_status",
  "description": "Check on a previously delegated Hermes task.",
  "parameters": {
    "type": "object",
    "properties": { "taskId": { "type": "string" } },
    "required": ["taskId"]
  }
}
```
→ bridge: `GET /v1/tasks/:taskId` → `Task`

### 3.3 `send_followup_to_hermes`
```json
{
  "name": "send_followup_to_hermes",
  "description": "Send additional information or a clarification to a task Hermes is already working on.",
  "parameters": {
    "type": "object",
    "properties": {
      "taskId": { "type": "string" },
      "message": { "type": "string" }
    },
    "required": ["taskId", "message"]
  }
}
```
→ bridge: `POST /v1/tasks/:taskId/followup` → `Task`

### 3.4 `cancel_hermes_task`
```json
{
  "name": "cancel_hermes_task",
  "description": "Cancel a Hermes task the user no longer wants performed.",
  "parameters": {
    "type": "object",
    "properties": {
      "taskId": { "type": "string" },
      "reason": { "type": "string" }
    },
    "required": ["taskId"]
  }
}
```
→ bridge: `POST /v1/tasks/:taskId/cancel` → `Task`

### 3.5 `approve_hermes_action`
```json
{
  "name": "approve_hermes_action",
  "description": "Approve or reject a sensitive action Hermes has paused on (e.g. before sending an email or spending money). Only call this after reading the pending approval back to the user and getting an explicit yes/no.",
  "parameters": {
    "type": "object",
    "properties": {
      "taskId": { "type": "string" },
      "approvalId": { "type": "string" },
      "decision": { "type": "string", "enum": ["approve", "reject"] },
      "note": { "type": "string" }
    },
    "required": ["taskId", "approvalId", "decision"]
  }
}
```
→ bridge: `POST /v1/tasks/:taskId/approve` → `Task`

All five map 1:1 onto `ios/HermesVoice/Core/Tools/*` handlers and
`bridge/src/http/routes/tasks.ts`. The Realtime function-call `name` is the JSON
key used for dispatch in `ToolRegistry.swift`.

---

## 4. Bridge REST API — `[IMPLEMENTED]`

Base path `/v1`. All request/response bodies are JSON. `GET /v1/health` and
`POST /v1/session` are the only routes that do not require a minted client
session. Every task, SSE, and Realtime-credential route requires
`Authorization: Bearer <sessionToken>`. The bridge hashes the token, resolves
its bound `hermesSessionId`, and never accepts a client-selected session ID.

### `POST /v1/session`
Mints an opaque client session. In production, `BRIDGE_BOOTSTRAP_SECRET` is
required and the endpoint expects `Authorization: Bearer <bootstrapSecret>`.
The static bootstrap credential is a deployment seam, not an app credential:
do not bundle it in iOS. Put authenticated login or device attestation in
front of this endpoint for a real multi-user deployment.

Response `201`:
```json
{
  "sessionToken": "<returned once>",
  "hermesSessionId": "hs_<opaque>",
  "expiresAt": "2026-07-15T18:05:00.000Z"
}
```

### `GET /v1/health`
No auth. `200 { "ok": true, "uptimeSeconds": number }`.

### `POST /v1/realtime/session`
Mint a fresh OpenAI Realtime ephemeral client credential.

Request:
```json
{ "voice": "marin" }
```
(`voice` optional, server has a default.)

Response `200`:
```json
{
  "sessionId": "sess_abc123",
  "model": "gpt-realtime-2.1",
  "clientSecret": { "value": "ek_...", "expiresAt": "2026-07-14T18:05:00.000Z" },
  "createdAt": "2026-07-14T17:05:00.000Z",
  "expiresInSeconds": 3600
}
```
`clientSecret.value` is the only thing the app ever sees; `OPENAI_API_KEY`
never leaves the server. Errors: `500 { error: "openai_api_key_missing" }` if
unconfigured (unless `BRIDGE_MOCK_OPENAI=1`, dev-only — see below), `502 {
error: "upstream_error", detail }` if OpenAI's API call fails.

Dev fallback: with `BRIDGE_MOCK_OPENAI=1` and no `OPENAI_API_KEY`, this
route returns a clearly-fake credential (`clientSecret.value` prefixed
`mock_ek_`) so the rest of the stack is exercisable without a real OpenAI
account. This is `[MOCKED]` and must never be enabled in production — the
bootstrap check script and `SECURITY.md` call this out.

### `POST /v1/tasks`
Body: `{ "instruction": string, "context"?: object, "clientRequestId"?: string }`
`201 Task` (or `200 Task` if `clientRequestId` was already seen for this
`hermesSessionId` — idempotent replay, not a duplicate task).

### `GET /v1/tasks`
Query `?status=` optional filter. `200 { "tasks": Task[] }` — all tasks for
the caller's `hermesSessionId`, newest first. Used to hydrate the task rail
on launch/reconnect; not one of the five Realtime tools.

### `GET /v1/tasks/:taskId`
`200 Task` or `404 { error: "task_not_found" }`.

### `POST /v1/tasks/:taskId/followup`
Body: `{ "message": string }`. `200 Task` or `409 { error: "task_terminal" }`
if the task already completed/failed/was canceled.

### `POST /v1/tasks/:taskId/cancel`
Body: `{ "reason"?: string }`. `200 Task` or `409 { error: "task_terminal" }`.

### `POST /v1/tasks/:taskId/approve`
Body: `{ "approvalId": string, "decision": "approve"|"reject", "note"?: string }`.
`200 Task` or `409 { error: "no_matching_approval" }`.

### `GET /v1/events`
`text/event-stream`, one long-lived connection per `hermesSessionId`
(reused across Realtime session rotations — this is how the task rail keeps
updating live even while the WebRTC leg is being rotated or is briefly
down). Named SSE events, `data:` is JSON:

| `event:` | `data` shape | When |
|---|---|---|
| `task.created` | `Task` | right after `POST /v1/tasks` |
| `task.progress` | `Task` | provider reports incremental progress |
| `task.approval_required` | `Task` | provider pauses on a gated action |
| `task.completed` | `Task` | terminal, success |
| `task.failed` | `Task` | terminal, failure |
| `task.canceled` | `Task` | terminal, user/model canceled |
| `ping` | `{ "ts": string }` | every 15s keepalive, no-op for clients |

### `Task` object
```ts
type TaskStatus = "queued" | "running" | "waiting_approval" | "completed" | "failed" | "canceled";

interface Task {
  id: string;                 // task_<uuid>
  hermesSessionId: string;
  status: TaskStatus;
  instruction: string;
  summary?: string;           // short human-readable current-state summary, for narration
  progress?: { percent?: number; message?: string };
  result?: unknown;
  error?: { message: string; code?: string };
  pendingApproval?: { approvalId: string; action: string; details?: Record<string, unknown>; requestedAt: string };
  createdAt: string;          // ISO8601
  updatedAt: string;          // ISO8601
  history: Array<{ at: string; kind: "created" | "followup" | "progress" | "approval_requested" | "approval_resolved" | "terminal"; message: string }>;
}
```

---

## 5. Hermes provider interface — `[IMPLEMENTED: mock + API Server]`

`bridge/src/hermes/provider.ts` defines the seam a real Hermes integration
plugs into:

```ts
interface HermesProvider {
  createTask(input: { taskId: string; hermesSessionId: string; instruction: string; context?: unknown }): Promise<void>;
  sendFollowup(taskId: string, message: string): Promise<void>;
  cancelTask(taskId: string, reason?: string): Promise<void>;
  resolveApproval(taskId: string, approvalId: string, decision: "approve" | "reject", note?: string): Promise<void>;
  onEvent(listener: (event: HermesProviderEvent) => void): () => void; // unsubscribe
}
```

`bridge/src/hermes/mockProvider.ts` is a working, deterministic-enough local
implementation used by default in tests and when Hermes API env vars are
unset: it queues a task, transitions `queued → running` immediately, emits
2-3 synthetic progress events, and completes after a short delay.
Instructions containing the literal word `"approve"` synthesize a
`waiting_approval` gate first, so the approve/reject path is exercisable
end-to-end without a real Hermes.

`bridge/src/hermes/apiServerProvider.ts` is the real integration against
Hermes API Server (`POST /v1/runs`, SSE `/v1/runs/{id}/events`, `/stop`,
`/approval`). Enable it by setting both `HERMES_API_BASE_URL` and
`HERMES_API_KEY` (see `.env.example`). The bridge keeps its own `task_*`
ids and maps them to Hermes `run_*` ids; follow-ups that arrive mid-run are
queued and drained as successive runs on the same `session_id`.
---

## 6. Session lifecycle & rotation — `[IMPLEMENTED on the reducer/coordinator level, SCAFFOLDED at the WebRTC binary level]`

OpenAI Realtime sessions are time-boxed. This system treats 60 minutes as a
hard ceiling and rotates proactively at **55 minutes**, well before
expiry, with a make-before-break handoff:

```
t=0        app launch: POST /v1/realtime/session → session A (expires ~t=60m)
                        RTCPeerConnection A established, datachannel open
t=55m      SessionCoordinator fires rotation timer
                        POST /v1/realtime/session → session B (new ephemeral secret)
                        RTCPeerConnection B established in parallel with A
           A stays live, narrating/listening, until B's datachannel reports
           "open" and a session.update ack is received on B
t=55m+Δ    swap: mic/audio track moved to B, A torn down
                        (Δ is typically sub-second; a brief dual-connection
                        window, not a gap, avoids dropping mid-utterance)
t=60m      session A would have expired here — irrelevant, already retired
```

What rotation does **not** disturb:
- `hermesSessionId` — unchanged, so `GET /v1/tasks` and the SSE stream at
  `/v1/events` keep working through an ordinary Realtime rotation without a
  reconnect.
- The task rail state in the iOS app — sourced from bridge, not from the
  Realtime session.

What rotation **does** lose, by construction of OpenAI ephemeral sessions,
and is a documented, honest limitation rather than a hidden one: the
Realtime model's own conversational context (its transcript/audio memory of
the call so far) does not carry over automatically. On successful rotation
the app seeds session B's instructions with a short system-generated recap
("You are continuing an in-progress voice session. N Hermes tasks are
in flight: ..."), built from bridge task-rail state, so the model can pick
the thread back up — but verbatim turn-by-turn memory of the pre-rotation
conversation is not preserved. See `docs/ARCHITECTURE.md` §"Known
limitations" for the full list.

Reconnection (network loss, not rotation) follows the same
make-before-break shape with exponential backoff (`1s, 2s, 4s, 8s, capped at
30s`), implemented in `SessionCoordinator` (`[IMPLEMENTED]` as a pure state
machine in `SessionReducer.swift`; the actual `RTCPeerConnection` calls are
behind the `RealtimeTransport` protocol — see `ARCHITECTURE.md` for the
concrete-vs-abstract boundary).

The client-session bearer is a separate lifecycle. If a bridge restart or
revocation makes a still-valid Keychain token unknown to the server, the
iOS client treats the first protected-route `401` as recoverable: it clears
that token, bootstraps exactly once with the operator credential, and retries
the request exactly once. A bootstrap `401` or a second protected-route `401`
is surfaced instead of looping, and the app asks for a corrected bootstrap
credential. The Debug build also exposes **Reset client session**, which
clears only the minted client token and reconnects; it does not erase the
operator's bootstrap credential.

---

## 7. Auth, CORS, rate limiting — `[IMPLEMENTED]`

- **Client-session auth**: `POST /v1/session` mints a random opaque bearer
  token bound server-side to a generated `hermesSessionId`. Only a SHA-256
  token hash is stored. Every task, SSE, and Realtime-session route resolves
  scope from this token. Client-supplied session IDs are ignored/rejected.
- **Bootstrap gate**: `BRIDGE_BOOTSTRAP_SECRET` gates session minting and is
  mandatory in production. It is not an iOS app secret. A real deployment
  must replace or front this seam with user login or device attestation.
- **CORS**: allowlist via `BRIDGE_CORS_ALLOWLIST` (comma-separated origins).
  No wildcard in production mode; wildcard only implicitly when the
  allowlist is empty *and* `NODE_ENV !== "production"`.
- **Rate limiting**: fixed-window per-IP-per-route counter,
  `BRIDGE_RATE_LIMIT_MAX` requests per `BRIDGE_RATE_LIMIT_WINDOW_MS`
  (defaults: 60 requests / 60_000ms). `429 { error: "rate_limited",
  retryAfterMs }` on breach. This is an in-memory dev-grade limiter, not a
  distributed one — see `SECURITY.md`.

---

## 8. Error envelope

Every non-2xx JSON response uses:
```json
{ "error": "machine_readable_code", "detail"?: "human readable string" }
```
