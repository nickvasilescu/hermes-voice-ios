# ARCHITECTURE

## Three systems, one narrow waist

- **OpenAI Realtime** (`gpt-realtime-2.1`, WebRTC) owns everything about
  the live conversation: speech-to-text, text-to-speech, voice activity
  detection, turn-taking, barge-in. It holds no durable state and knows
  nothing about Hermes except five function-call tools.
- **Hermes** owns durable work: tasks that outlive a single voice turn,
  memory, side-effecting tools (email, calendar, code, whatever a real
  deployment wires up).
- **`bridge/`** is the narrow waist. It never touches audio. Its only jobs:
  mint short-lived OpenAI credentials so the iOS app never holds a real API
  key, and expose a small REST+SSE surface over task lifecycle so the app
  doesn't need to speak Hermes' native protocol.

Full request/response/event contracts live in `docs/PROTOCOL.md` — this
document is about how the pieces fit and what's real vs. scaffolded.

## Backend (`bridge/`) — [IMPLEMENTED]

```
src/app.ts              assembles the Express app from injected deps (testable
                         without a network: fake fetch, mock provider, in-proc server)
src/server.ts            real entrypoint: loads env, listens
src/config.ts             pure env → Config parsing, unit tested in isolation
src/tasks/store.ts        in-memory Task CRUD + idempotency + history
src/tasks/events.ts       per-hermesSessionId pub/sub, decoupled from HTTP
src/tasks/service.ts      the one place that wires store + provider + events together
src/hermes/provider.ts    HermesProvider interface — the real integration seam
src/hermes/mockProvider.ts a working local simulator (see below)
src/openai/realtimeClient.ts  ephemeral session minting against OpenAI
src/http/*                routes, zod validation, auth/cors/rate-limit middleware
```

Why this shape: `TaskService` is the only place that understands how an
HTTP request, a `HermesProvider` event, and an SSE broadcast relate to each
other. Routes stay thin (parse → call service → respond), the store and
event bus are independently unit-tested, and the provider event pipeline is
exercised through `TaskService`, not duplicated per-route. This is why
`bridge/test/taskService.test.ts` covers full task lifecycles without an
HTTP server, while `bridge/test/http.*.test.ts` mostly checks status codes,
headers, and wiring, not business logic a second time.

**`MockHermesProvider` is a real, honest mock**, not a stub: it's
deterministic-enough, asynchronous (progress arrives via `setTimeout`, not
synchronously), and supports the full lifecycle including the approval
gate (any instruction containing "approve" pauses for one). It is the
default provider in tests and when Hermes API env vars are unset.

**`ApiServerHermesProvider`** talks to a live Hermes API Server
(`HERMES_API_BASE_URL` + `HERMES_API_KEY`). `createApp` selects it
automatically when both are set; otherwise the mock is used. See
`docs/PROTOCOL.md` §5 and `.env.example`.

### Client scope is not conversation scope

The historical `hermesSessionId` name is retained on the wire for backward
compatibility, but it now has one job: identify the authenticated client's
task/SSE ownership scope. `TaskStore` mints a separate `hermesThreadId` for
every new durable task. `ApiServerHermesProvider` sends that task thread as
Hermes' `session_id` and reuses it only for follow-up runs on the same task.

This avoids both bad extremes: every utterance becoming context-free and every
unrelated job accumulating in one permanent Hermes conversation. A follow-up,
approval, or correction stays attached to its task; an independent delegation
starts with clean Hermes context. Cross-task context must be passed explicitly
through task input/context rather than leaking implicitly through a shared
session.

**OpenAI ephemeral session minting is a real network call** to
`https://api.openai.com/v1/realtime/client_secrets` with a real request
shape (see `docs/PROTOCOL.md` §4). Its response parsing is deliberately
defensive rather than assuming one exact schema. The client-secret request
also sends the opaque server-owned client scope as
`OpenAI-Safety-Identifier`, following current Realtime guidance without
exposing user PII.

## iOS (`ios/HermesVoice`) — [IMPLEMENTED and simulator-tested]

The generated Xcode project resolves Stasel WebRTC and the app plus unit-test
target build on macOS. `make ios-test` regenerates the project and runs the
suite on an installed iPhone simulator. Physical-device microphone and audio
routing remain an acceptance-test concern.

### Core/Reducer — pure state machine [IMPLEMENTED]

`SessionState` + `SessionReducer.reduce(_:_:) -> [Effect]` is a classic
Elm/Redux-style reducer: given the current state and one `SessionEvent`
(a Realtime wire event, a bridge task update, a timer firing, ...), it
returns the new state and a list of `Effect`s describing what the outside
world should do. It imports only `Foundation` — no networking, no
`SwiftUI`, no `WebRTC` — which is what makes `SessionReducerTests.swift`
a plain, fast unit test target rather than something requiring a
simulator.

**Honest scope note:** the reducer models one connection's turn-taking
(listening → thinking → speaking, tool-call bookkeeping, barge-in
detection) and *signals* rotation/reconnect intent via effects
(`.scheduleRotationTimer`, `.mintRealtimeSession`, `.scheduleReconnect`).
It does not itself model "two WebRTC peer connections briefly alive at
once during rotation" — that cross-connection choreography lives in
`SessionCoordinator`, which is imperative by necessity (it's sequencing
side effects across two live network objects). Reasonable engineers can
disagree about exactly where this line should sit; the point is that it
*is* a deliberate line, not an oversight.

### Core/Transport — the WebRTC boundary [IMPLEMENTED]

`RealtimeTransport` is the protocol `SessionCoordinator` codes against.
`WebRTCRealtimeTransport` does the HTTPS SDP offer/answer exchange and
translates data-channel bytes to/from `RealtimeServerEvent` and
`RealtimeClientEvent`. It creates the peer connection, local audio track, and
`oai-events` data channel through `StaselWebRTCEngine`. The narrow engine
protocol keeps the unofficial binary dependency replaceable and lets the
coordinator preserve microphone state across reconnects and make-before-break
rotations.

### Core/Tools — the five tools [IMPLEMENTED]

Each tool is a small `HermesTool` conformance: decode Realtime's function
arguments, call one `BackendClientProtocol` method, encode a compact
`HermesTaskSummary` (not the full `Task` with history — every token here
costs conversation latency) back as the tool result.
`DelegateToHermesTool` uses the Realtime `call_id` as `clientRequestId`,
which ties Realtime's own function-call retry semantics directly to the
bridge's idempotency contract (`docs/PROTOCOL.md` §2) — a retried call
never spawns a duplicate task.

### Core/Networking — bridge client [IMPLEMENTED]

`BackendClient` is a plain `URLSession`-based REST client (testable via
`URLProtocol` stubbing, see `BackendClientTests.swift`) and `SSEClient` is
a minimal Server-Sent-Events reader over `URLSession.bytes(for:)`. Its
line-stream opener is injectable, so HTTP status, framing, EOF, transport
failure, replacement, and cancellation are deterministic unit-test inputs.
The Store owns SSE policy: capped exponential reconnect backoff plus exactly
one `401` client-session recovery before prompting for the bootstrap
credential. Neither networking client depends on the reducer or transport
layer.

### Features — SwiftUI [IMPLEMENTED]

One ambient orb (`AmbientOrbView`) remains the primary surface. A control bar
offers immediate response Stop plus persistent voice Pause/Resume; pause
disables microphone and narration without stopping Hermes work. A persistent,
expandable activity surface combines optimistic delegations with authoritative
REST/SSE task state. `clientRequestId` correlation replaces each “Sending…”
row with its real task without matching on human-readable text. This remains
deliberately not a chat transcript UI — see `docs/PRODUCT.md` for why.

## Known limitations

- **WebRTC is an external binary dependency.** The app uses Stasel WebRTC
  through `StaselWebRTCEngine`; package resolution, licensing, binary size,
  physical-device audio behavior, and future upstream updates remain release
  concerns rather than an abstract transport gap.
- **Physical-device audio needs regression coverage.** The Swift test suite
  runs on this Mac, but microphone/audio-route failures still require a real
  iPhone acceptance pass.
- **OpenAI Realtime response parsing is intentionally defensive.**
  `realtimeClient.ts` validates the credential, expiry, and session id while
  accepting documented top-level and nested client-secret shapes.
- **Realtime conversational memory does not survive rotation.** OpenAI
  ephemeral sessions are independent; rotating seeds a short recap from
  bridge task-rail state, but verbatim turn-by-turn memory is not
  preserved. See `docs/PROTOCOL.md` §6.
- **In-memory dev store only.** `TaskStore` is a `Map`; nothing survives a
  `bridge/` process restart. Fine for local dev/demo, not for production —
  see `docs/SECURITY.md`.
- **No task detail view.** Tapping a task-rail card is not wired to a
  detail sheet; the rail is read-only glanceable state today.
