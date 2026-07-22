# Contributing

Thanks for improving Hermes Voice. The repository is intentionally split into
a small TypeScript bridge, a SwiftUI client, and an explicit protocol between
them. Most regressions happen when only one side of that protocol changes.

## Development setup

1. Read [`AGENTS.md`](AGENTS.md) and [`docs/PROTOCOL.md`](docs/PROTOCOL.md).
2. Install Node.js 22+, Xcode, an iOS Simulator runtime, and
   [XcodeGen](https://github.com/yonaskolb/XcodeGen).
3. Run:

```bash
make check
make ios-test
```

For live voice, copy `.env.example` to `bridge/.env` and follow
[`docs/SETUP.md`](docs/SETUP.md). Never commit the resulting file.

## Ground rules

- Update `docs/PROTOCOL.md` with every request, response, SSE, Realtime event,
  tool-schema, or identifier-lifecycle change.
- Add or update tests with behavior changes. Bridge work should cover the
  service layer and HTTP edge where appropriate; iOS work should cover the
  reducer or injected networking boundary.
- Preserve the five-tool boundary and server-owned session scope described in
  `AGENTS.md`.
- Be explicit about what is implemented, mocked, or not production-ready.
- Do not commit API keys, tokens, `.env` files, local xcconfigs, signing
  identities, private hostnames, or operator-specific deployment inventory.
- Do not modify the generated `.xcodeproj`. Change `project.yml` and regenerate.

## Pull requests

Keep changes focused. In the description, include:

- the user-visible outcome;
- protocol or security implications;
- tests actually run and their results;
- screenshots for visible SwiftUI changes; and
- any hardware/live-service behavior not verified.

Use short imperative commit subjects, such as `Add task approval recovery`.

## Commands

```bash
make bridge-install   # npm ci/install dependencies
make bridge-dev       # local bridge on 127.0.0.1:8787
make bridge-typecheck
make bridge-test
make ios-generate
make ios-test
make check
```

## Security reports

Do not open a public issue for a suspected vulnerability or exposed secret.
Follow [`SECURITY.md`](SECURITY.md).
