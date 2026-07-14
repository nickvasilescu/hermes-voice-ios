# Hermes Voice

An iPhone-first voice frontend for **Hermes** built on OpenAI Realtime
(`gpt-realtime-2.1`, WebRTC). Realtime owns speech, turn-taking, and
barge-in; Hermes owns durable tasks, memory, and tools; a small Node
backend (`bridge/`) is the narrow waist between them.

Talk to it like a person. It listens, thinks out loud a little, and hands
anything durable — "book me a table," "draft that email," "check on the
thing from this morning" — off to Hermes, which works in the background and
reports back through the same voice conversation while a lightweight task
rail shows what's in flight.

```
   iPhone (ios/HermesVoice)
   ┌─────────────────────────┐        WebRTC (audio + data)      ┌──────────────────┐
   │  Ambient orb + task rail │ ─────────────────────────────────▶│ OpenAI Realtime  │
   │  SwiftUI, pure reducer   │◀─────────────────────────────────  │ gpt-realtime-2.1 │
   └─────────────┬────────────┘                                    └──────────────────┘
                 │  HTTPS (REST + SSE)
                 ▼
   ┌─────────────────────────┐   HermesProvider interface   ┌──────────────────┐
   │  bridge/ (Node 22, TS)  │ ─────────────────────────────▶│  Hermes           │
   │  session mint, tasks,   │◀───────────────────────────── │  [SCAFFOLDED /    │
   │  SSE, auth, rate limit  │                                │   MOCKED locally] │
   └─────────────────────────┘                                └──────────────────┘
```

## Status at a glance

| Piece | Status |
|---|---|
| `bridge/` backend (REST + SSE, auth, CORS, rate limiting) | **[IMPLEMENTED]** — 74 tests passing, strict TypeScript |
| `MockHermesProvider` (local task simulator) | **[IMPLEMENTED]**, honestly a mock — see PROTOCOL.md §5 |
| Real Hermes integration | **[SCAFFOLDED]** — `HermesProvider` interface only, no backend wired |
| OpenAI ephemeral session minting | **[IMPLEMENTED]** as a real call; response schema is best-effort (see PROTOCOL.md §4) |
| iOS app structure, state machine, tools, networking | **[IMPLEMENTED]** as source, **not compiled** in this environment (no Xcode/Swift toolchain here) |
| WebRTC transport (peer connection engine) | **[SCAFFOLDED]** — signaling/SDP exchange is real; no concrete libwebrtc binary is vendored |

See `docs/ARCHITECTURE.md` for the full breakdown and why each boundary is
drawn where it is.

## Repo layout

```
bridge/                Node 22 + TypeScript backend
  src/tasks/            task store, event bus, orchestration service
  src/hermes/           HermesProvider interface + local mock
  src/http/             routes, validation, middleware (auth/cors/rate limit)
  src/openai/           ephemeral Realtime session client
  test/                 74 tests, node:test

ios/HermesVoice/        SwiftUI app source (XcodeGen project.yml)
  Core/Reducer/          pure state machine, Realtime wire event (de)coding
  Core/Tools/            the five Realtime-facing tools
  Core/Transport/        WebRTC abstraction + honest concrete boundary
  Core/Networking/       REST/SSE client against bridge/
  Features/              ambient orb, task rail, root view
ios/HermesVoiceTests/   XCTest suite for the above

docs/                   PROTOCOL, ARCHITECTURE, SECURITY, PRODUCT
```

## Quickstart

### Backend

```bash
cd bridge
npm install
cp ../.env.example .env   # then edit — see below
npm run dev                # http://localhost:8787
```

Without an `OPENAI_API_KEY`, `POST /v1/realtime/session` returns `500
openai_api_key_missing` — set `BRIDGE_MOCK_OPENAI=1` in `.env` to get an
obviously-fake credential instead and exercise the rest of the stack
without an OpenAI account. `MockHermesProvider` is the default task
provider either way, so task delegation/progress/approval flows work fully
locally regardless of OpenAI configuration.

```bash
npm run typecheck   # tsc --noEmit, strict
npm test            # node:test, 74 tests
```

### iOS

Requires Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen) (macOS
only — this repo was built without either, see "Known limitations"):

```bash
cd ios/HermesVoice
xcodegen generate
open HermesVoice.xcodeproj
```

Set `BRIDGE_BASE_URL` in `Config/Debug.xcconfig` to your bridge's address
(the iOS Simulator can reach `http://localhost:8787` directly; a physical
device needs your Mac's LAN IP or a tunnel). Voice will not actually
connect until a concrete `WebRTCEngine` is wired into
`WebRTCRealtimeTransport` — see `docs/ARCHITECTURE.md`.

### Everything at once

```bash
make check   # backend typecheck + test, secrets hygiene, tooling check
```

## The five tools

Realtime's only capability is these five function calls — see
`docs/PROTOCOL.md` §3 for exact JSON schemas:

`delegate_to_hermes` · `get_hermes_task_status` · `send_followup_to_hermes`
· `cancel_hermes_task` · `approve_hermes_action`

`hermesSessionId` is never a parameter the model supplies — it's injected
by the iOS tool executor from app state.

## Docs

- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — REST/SSE contracts, tool
  schemas, session rotation protocol. Source of truth.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit,
  what's implemented vs. scaffolded vs. mocked, and why.
- [`docs/SECURITY.md`](docs/SECURITY.md) — auth, secrets handling, threat
  model, what's dev-grade vs. production-grade today.
- [`docs/PRODUCT.md`](docs/PRODUCT.md) — what this app is for, the core
  interaction loop, and what's explicitly out of scope for the MVP.

## License

MIT — see [`LICENSE`](LICENSE).
