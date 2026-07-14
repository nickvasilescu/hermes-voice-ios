# CLAUDE.md

Guidance for AI coding agents (Claude Code or similar) working in this repo.

## What this repo is

An iPhone-first OpenAI Realtime (`gpt-realtime-2.1`, WebRTC) voice frontend
for "Hermes," a separate durable task/memory/tool system. Realtime owns
speech and turn-taking; Hermes owns durable work; `bridge/` is the narrow
waist between them. Read `docs/PROTOCOL.md` before touching any request/
response shape, tool schema, or SSE event — it is the source of truth both
`bridge/` and `ios/HermesVoice` are built against.

## Non-negotiables

- **Never invent secrets.** No API keys, tokens, or plausible-looking
  credentials in code, tests, docs, or commit messages. Tests that need an
  OpenAI response use an injected fake `fetch`, never a real key.
- **Don't claim iOS compiles or tests pass unless you actually ran them.**
  This Mac has Xcode; use `make ios-test` (or `xcodegen generate` +
  `xcodebuild test -scheme HermesVoice`) and report real results. If a
  simulator runtime is missing, `xcodebuild -downloadPlatform iOS` first.
  Never assert green without running.
- **`bridge/` changes need tests run for real.** `npm run typecheck && npm
  test` inside `bridge/`, not just "should pass." Paste/report actual
  results.
- **Keep the five tools exactly five.** `delegate_to_hermes`,
  `get_hermes_task_status`, `send_followup_to_hermes`, `cancel_hermes_task`,
  `approve_hermes_action`. Don't add a sixth tool as a convenience — extend
  one of the five or push the capability into Hermes itself.
- **`hermesSessionId` is never model-controlled.** It's injected by the iOS
  tool executor from app state, never a parameter the Realtime model
  supplies. Don't change tool schemas to accept it.

## Where things live

- `docs/PROTOCOL.md` — REST/SSE contracts, tool JSON schemas, session
  rotation protocol. Read this first.
- `bridge/src/tasks/service.ts` — the one place that knows how HTTP calls,
  the Hermes provider, the in-memory store, and SSE events fit together.
- `bridge/src/hermes/provider.ts` / `mockProvider.ts` — the seam a real
  Hermes integration plugs into, and the local mock standing in for it.
- `ios/HermesVoice/Core/Reducer` — pure, platform-agnostic session state
  machine (Realtime events in, app state + effects out). Keep it free of
  networking/UIKit/SwiftUI imports so it stays unit-testable.
- `ios/HermesVoice/Core/Transport` — the WebRTC abstraction boundary. The
  protocol is real; the concrete binary WebRTC dependency is intentionally
  not wired up (see `docs/ARCHITECTURE.md`). Don't silently "complete" this
  by vendoring a WebRTC binary without flagging it clearly — that's a real
  decision (which SDK, license, binary size) for a human to make.

## Workflow expectations

1. Change `docs/PROTOCOL.md` first if the contract changes, then code on
   both sides of it.
2. TDD for `bridge/`: red test, then implementation, then green — and
   actually run it.
3. Keep status labels (`[IMPLEMENTED]` / `[SCAFFOLDED]` / `[MOCKED]`)
   accurate when you touch a file that has one.
4. Don't commit or push unless explicitly asked to in the current request.
