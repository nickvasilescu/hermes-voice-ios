# Contributing

## Ground rules

1. **`docs/PROTOCOL.md` is the contract.** If you change a request/response
   shape, an SSE event, or a tool schema, update `docs/PROTOCOL.md` in the
   same change. Code and docs disagreeing is treated as a bug.
2. **Test-first for `bridge/`.** Add or update a `bridge/test/*.test.ts`
   file that fails for the right reason before writing the implementation.
   Every PR touching `bridge/src` should touch `bridge/test` too, unless
   it's a pure refactor with no behavior change (say so in the PR).
3. **Be honest about status.** This repo distinguishes `[IMPLEMENTED]`,
   `[SCAFFOLDED]`, and `[MOCKED]` throughout the docs. If you scaffold
   something rather than fully implement it, say so in the code comment and
   in the relevant doc — don't let it read as finished.
4. **No secrets, ever.** No API keys, tokens, or `.env` files in commits.
   `bootstrap/check.sh` fails the build if `bridge/.env` is tracked.

## Backend (`bridge/`)

```bash
cd bridge
npm install
npm run typecheck   # tsc --noEmit, strict
npm test            # node's built-in test runner, node:test
npm run dev          # local server with mock Hermes provider by default
```

- Runtime: Node 22, TypeScript strict, ESM (`"type": "module"`).
- Keep dependencies minimal. Before adding one, check whether Node's
  standard library already covers it (this repo deliberately uses
  `node:crypto` for UUIDs and `node:test` instead of adding `uuid` or a
  third-party test runner).
- Business logic belongs in `src/tasks/service.ts` and friends, not in
  route handlers — routes should stay thin (parse, call service, respond).

## iOS (`ios/HermesVoice`)

This repo was built without access to Xcode or a Swift toolchain (Linux
dev environment). That means:
- Swift source under `ios/HermesVoice` is written and reviewed for
  correctness by hand, but **not compiled or run in this repo's CI**.
- The pure reducer/codec logic (`Core/Reducer/*`) is written to be testable
  with plain XCTest/Swift Testing once you have Xcode — please add tests
  there for new reducer behavior, and run them locally with
  `xcodebuild test` or in Xcode before opening a PR.
- After editing `project.yml`, regenerate the Xcode project with
  `make ios-generate` (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen))
  and confirm it builds in Xcode before pushing.

## Commit style

Short, imperative subject lines (`Add task cancellation route`, not `Added`
or `Adding`). Explain *why* in the body when it isn't obvious from the diff.

## Running everything

```bash
make check   # typecheck + test the backend, sanity-check secrets/tooling
```
