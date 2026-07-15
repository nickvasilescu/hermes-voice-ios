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

**OpenAI ephemeral session minting is a real network call** to
`https://api.openai.com/v1/realtime/client_secrets` with a real request
shape (see `docs/PROTOCOL.md` §4). Its response parsing is deliberately
defensive rather than assuming one exact schema, because this repo was
built without live network access to OpenAI to verify the current
`gpt-realtime-2.1` response shape byte-for-byte — re-verify against current
OpenAI docs before depending on it in production.

## iOS (`ios/HermesVoice`) — source written, not compiled here

This repo was built in a Linux environment with no Xcode and no Swift
toolchain (`swift --version` fails). Every Swift file here was written and
reviewed for correctness by hand, but **none of it has been compiled,
typechecked by `swiftc`, or run** in this repo's history. Treat it as a
careful first draft to open in Xcode, not as verified-working code. See
`CONTRIBUTING.md` for how to actually build/test it.

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

### Core/Transport — the WebRTC boundary [SCAFFOLDED at the binary level]

`RealtimeTransport` is the protocol `SessionCoordinator` codes against.
`WebRTCRealtimeTransport` is the one concrete implementation, and it is
real up to a specific point: it does the actual HTTPS SDP offer/answer
exchange against OpenAI's Realtime WebRTC endpoint (real request shape,
real headers, real error handling), and it translates data-channel bytes
to/from `RealtimeServerEvent`/`RealtimeClientEvent`. What it does *not* do
is create an actual `RTCPeerConnection` — that's behind a narrow
`WebRTCEngine` protocol with zero shipped implementations.

This is a deliberate stop, not a gap someone forgot: adding a real engine
means vendoring a WebRTC binary (e.g.
[stasel/WebRTC](https://github.com/stasel/WebRTC), an unofficial build of
Google's libwebrtc — there is no first-party Apple WebRTC framework). That
decision has real consequences — ~30-50MB added to app size, a license to
review, a binary this repo can't audit from a sandboxed Linux environment
without network access — so `CLAUDE.md` explicitly asks a human to make it
rather than have an agent silently pick one. `HermesVoiceApp.swift`
constructs the transport with `engine: nil`, so this fails loudly
(`.noEngineConfigured`) instead of pretending to work.

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
a minimal Server-Sent-Events reader over `URLSession.bytes(for:)`. Neither
depends on the reducer or transport layer.

### Features — SwiftUI [IMPLEMENTED as source]

One ambient orb (`AmbientOrbView`) as the primary surface, colored/animated
by `ConversationPhase`, plus a secondary horizontal task rail
(`TaskRailView`) sourced straight from `SessionState.tasks`. Deliberately
not a chat transcript UI — see `docs/PRODUCT.md` for why.

## Known limitations

- **WebRTC is an external binary dependency.** The app uses Stasel WebRTC
  through `StaselWebRTCEngine`; package resolution, licensing, binary size,
  physical-device audio behavior, and future upstream updates remain release
  concerns rather than an abstract transport gap.
- **Physical-device audio needs regression coverage.** The Swift test suite
  runs on this Mac, but microphone/audio-route failures still require a real
  iPhone acceptance pass.
- **OpenAI Realtime response schema is best-effort.** `realtimeClient.ts`
  parses defensively but was written without a live call to verify the
  exact current `client_secrets` response shape for `gpt-realtime-2.1`.
- **Realtime conversational memory does not survive rotation.** OpenAI
  ephemeral sessions are independent; rotating seeds a short recap from
  bridge task-rail state, but verbatim turn-by-turn memory is not
  preserved. See `docs/PROTOCOL.md` §6.
- **SSE has no general reconnect/backoff loop.** An authentication `401`
  performs one client-session recovery and resubscribe, but an unrelated
  dropped SSE connection still waits for the next app `start()` (Realtime
  reconnect is implemented separately).
- **In-memory dev store only.** `TaskStore` is a `Map`; nothing survives a
  `bridge/` process restart. Fine for local dev/demo, not for production —
  see `docs/SECURITY.md`.
- **No task detail view.** Tapping a task-rail card is not wired to a
  detail sheet; the rail is read-only glanceable state today.
