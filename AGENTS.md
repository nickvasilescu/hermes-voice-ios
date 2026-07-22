# Agent operating guide

This file is the durable contract for coding agents working in Hermes Voice.
Read it completely before changing the repository, then read
`docs/PROTOCOL.md` and the relevant component documentation.

## Mission

Hermes Voice is an iPhone-first voice frontend with three deliberate owners:

- OpenAI Realtime owns live speech, turn-taking, and tool selection.
- Hermes owns durable work, memory, and side-effecting tools.
- `bridge/` mints short-lived Realtime credentials and exposes task state over
  a narrow authenticated REST/SSE API. It never proxies audio.

Do not blur these boundaries for convenience.

## Start here

```bash
git status --short
make check
```

On macOS with Xcode and an iOS Simulator runtime:

```bash
make ios-test
```

Never report a build or test as passing unless you ran it in the current
workspace and saw a successful exit.

## Non-negotiable invariants

1. `docs/PROTOCOL.md` is the wire-contract source of truth. Change it in the
   same patch as any REST body, SSE event, Realtime event, tool schema, or
   identifier lifecycle.
2. Realtime receives exactly five tools:
   `delegate_to_hermes`, `get_hermes_task_status`,
   `send_followup_to_hermes`, `cancel_hermes_task`, and
   `approve_hermes_action`.
3. `hermesSessionId` is an authenticated client ownership scope, not a model
   parameter and not a Hermes conversation. The client cannot choose it.
4. Each independent task gets a new `hermesThreadId`. Follow-ups reuse the
   existing task's thread. Never put unrelated tasks into one implicit Hermes
   conversation.
5. The standard `OPENAI_API_KEY` and `HERMES_API_KEY` stay on the bridge.
   iOS receives only a short-lived Realtime client secret and its own opaque
   bridge session token.
6. Pausing voice must not pause REST, SSE, tool execution, or Hermes tasks.
   Stopping speech must not cancel a Hermes task.
7. Tool calls are idempotent by Realtime `call_id`; duplicate delivery must not
   duplicate side effects.
8. Never invent example credentials. Use empty values, `example.com`, or
   unmistakably invalid placeholders.

## Change map

| Concern | Start with | Also inspect |
|---|---|---|
| REST/SSE contract | `docs/PROTOCOL.md` | `bridge/src/http`, `bridge/src/types.ts`, iOS networking models |
| Task lifecycle | `bridge/src/tasks/service.ts` | store, event bus, provider, HTTP tests |
| Hermes behavior | `bridge/src/hermes/provider.ts` | mock and API Server providers |
| Realtime events/tools | `ios/HermesVoice/Core/Reducer/RealtimeWireEvent.swift` | reducer, tool registry, protocol doc |
| Voice lifecycle | `SessionReducer.swift` | `SessionCoordinator.swift`, transport tests |
| REST/SSE client | `BackendClient.swift`, `SSEClient.swift` | session manager and store tests |
| SwiftUI | `Features/` | reducer state; keep networking out of views |
| Build settings | `ios/HermesVoice/project.yml` | `Config/*.xcconfig`, never the generated project |

## Implementation rules

- Preserve the reducer boundary. `SessionReducer` decides state and effects;
  `HermesVoiceStore` performs asynchronous work.
- Keep route handlers thin. Validation belongs at the HTTP edge and lifecycle
  logic belongs in `TaskService`.
- Use the mock provider in tests. No test may require a real OpenAI key, Hermes
  key, network tunnel, or developer account.
- Add a regression test for every bug fix, at the lowest layer that proves the
  failure.
- Treat Foundation JSON encoding as observable protocol behavior. When OpenAI
  applies decimal precision constraints, assert the emitted bytes, not only the
  in-memory numeric value.
- Keep status claims honest: implemented, mocked, or a documented limitation.
- Do not edit or commit `HermesVoice.xcodeproj`; regenerate it with XcodeGen.
- Do not commit or push unless the user explicitly requests it.

## Verification matrix

| Change | Minimum verification |
|---|---|
| Bridge source | `cd bridge && npm run typecheck && npm test` |
| REST/SSE schema | Bridge tests, iOS decoder/client tests, protocol diff |
| Reducer/tool logic | Relevant XCTest class, then `make ios-test` |
| SwiftUI | `make ios-test`, simulator build, and visual inspection |
| WebRTC/session lifecycle | Coordinator/reducer tests plus physical-device check when available |
| Docs/config only | `make check`, link/path inspection, secret scan |

Before handoff, also run `git diff --check` and inspect `git status --short` so
generated files, `.env`, credentials, logs, and local signing overrides are not
included.

For a visible UI change, regenerate the deterministic network-free README
screenshots with `make readme-images` and inspect both PNGs before committing.

## Security checklist

- Never print or paste secret values into logs, tests, screenshots, issues, PRs,
  or chat.
- Never place credentials in `.env.example`, Swift, xcconfig, plist, launch
  arguments, or committed deployment files.
- Keep `bridge/.env` and `Config/Local.xcconfig` local and ignored.
- Use short-lived client credentials for mobile WebRTC. Do not connect the app
  with a standard OpenAI API key.
- Production needs real user/device authentication, TLS, durable storage,
  shared rate limiting, audit logging, and explicit retention policy. Do not
  describe the development bridge as production-ready.
- If a secret is found in history, stop. Do not merely delete the current line:
  revoke/rotate it and coordinate history rewriting before publication.

## Agent handoff format

End with:

- the concrete outcome;
- files changed and why;
- exact commands/tests run and their result;
- any limitation not verified on hardware or a live service;
- whether anything was committed, pushed, deployed, or otherwise changed
  outside the workspace.
