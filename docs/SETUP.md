# Setup and troubleshooting

This guide takes a fresh clone to a working Simulator or physical-device voice
session. No standard API key belongs on the phone.

## 1. Install prerequisites

- Node.js 22 or newer
- Xcode with an iOS 17+ Simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An OpenAI API key for live voice
- Optional: a Hermes API Server and its API key

Verify the repository before adding local credentials:

```bash
make check
make ios-test
```

## 2. Configure the bridge

```bash
cp .env.example bridge/.env
```

For a live voice session, edit the ignored `bridge/.env` and set:

```dotenv
OPENAI_API_KEY=
OPENAI_REALTIME_MODEL=gpt-realtime-2.1
BRIDGE_MOCK_OPENAI=0
```

Fill `OPENAI_API_KEY` locally. Do not paste its value into documentation,
issues, agent prompts, shell commands that will be logged, or iOS settings.

The default `MockHermesProvider` needs no additional configuration. To use a
real Hermes API Server, also set:

```dotenv
HERMES_API_BASE_URL=http://127.0.0.1:8642
HERMES_API_KEY=
```

Set `HERMES_API_KEY` locally. The bridge selects the real provider only when
both values are present.

Start the bridge:

```bash
make bridge-install
make bridge-dev
```

In another terminal:

```bash
curl --fail http://127.0.0.1:8787/v1/health
```

The response should contain `"ok":true`.

### Development without OpenAI

`BRIDGE_MOCK_OPENAI=1` returns an unmistakably fake ephemeral credential and
lets bridge tests or task flows run without an OpenAI account. It does not make
a working Realtime voice connection.

### Bootstrap credential

Outside production, an empty `BRIDGE_BOOTSTRAP_SECRET` leaves `POST /v1/session`
open for local development. Production fails closed when it is absent.

For a shared test bridge, generate and store a strong value in your secret
manager, then inject it as `BRIDGE_BOOTSTRAP_SECRET`. Do not add it to a public
deployment manifest. The app prompts once and stores the value in Keychain.
This seam is for controlled testing; production should use real user or device
authentication.

## 3. Configure iOS

Generate the project:

```bash
cd ios/HermesVoice
xcodegen generate
```

Do not commit `HermesVoice.xcodeproj`; `project.yml` is the source of truth.

### Simulator

The public Debug default is `http://127.0.0.1:8787`. Run the bridge on the same
Mac, open `HermesVoice.xcodeproj`, choose an iPhone Simulator, and run the
`HermesVoice` scheme.

### Physical iPhone

An iPhone cannot use the Mac's loopback address. Give the bridge a reachable
HTTPS endpoint, then create the ignored local override:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Set these non-secret build values:

```xcconfig
BRIDGE_BASE_URL = https:/$()/bridge.example.com
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.HermesVoice
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

`BRIDGE_BASE_URL` is visible in the app bundle. It is not a credential. Never
put `OPENAI_API_KEY`, `HERMES_API_KEY`, a bootstrap credential, or a bearer
token in this file.

Connect and trust the iPhone, select it as the Xcode destination, and run. The
first microphone request must be accepted for voice to work.

## 4. Expected first run

1. iOS calls `POST /v1/session` and stores the returned client session in
   Keychain.
2. It opens the task SSE stream and hydrates existing tasks.
3. The bridge mints a short-lived OpenAI Realtime client secret.
4. iOS posts its SDP offer directly to OpenAI and waits for `session.updated`.
5. The orb changes to **Listening**.

Ask for an independent durable task. It should appear in Activity immediately,
before REST or SSE confirms it. A follow-up to that task should retain its
`hermesThreadId`; a new objective should receive a different one.

## Troubleshooting

### “Could not bootstrap a client session”

Check the system from the outside in:

1. Confirm `BridgeBaseURL` in the built app points at the intended bridge.
2. Request `/v1/health` from a network the phone can reach.
3. Confirm the bridge process listens on the configured interface and port.
4. Check whether `POST /v1/session` returns `401` because the bootstrap
   credential is missing or stale.
5. In a Debug build, use **Reset client session** after a bridge restart or
   session revocation.

A healthy, launchable iPhone does not prove the bridge is reachable.

### `sessionConfigurationFailed`: maximum decimal places exceeded

Use the current code. Swift `Double(0.7)` can serialize as
`0.69999999999999996`; the app deliberately encodes the VAD threshold as an
exact decimal and has a byte-level regression test. Do not replace it with a
plain `Double` literal.

### The assistant interrupts itself on speakerphone

The app uses WebRTC voice processing plus explicit server VAD settings:
threshold `0.7`, `300 ms` prefix padding, and `700 ms` silence duration. Verify
the device audio route in logs and check whether `speech_started` arrives while
an assistant response is active. Headphones are a useful control test. Increase
the threshold only with physical-device evidence; higher values can miss quiet
users.

### Tasks do not appear

Verify all three paths:

- the optimistic row is created when `delegate_to_hermes` arrives;
- `POST /v1/tasks` returns a task with matching `clientRequestId`; and
- `/v1/events` stays connected and sends named `task.*` events.

The UI should not wait for SSE before showing a delegation.

### Unrelated requests share Hermes context

Inspect `Task.hermesThreadId`, not the legacy `hermesSessionId` name. Every new
task must get a new thread; only follow-ups reuse it. The client session remains
shared because it is an authentication/ownership scope.

### OpenAI session mint returns `502`

Inspect the redacted bridge error and confirm:

- the standard API key is valid and server-side;
- `OPENAI_REALTIME_URL` is the current client-secrets endpoint;
- `OPENAI_REALTIME_MODEL` is available to the project; and
- `BRIDGE_MOCK_OPENAI` is not accidentally enabled in production.

See the current [OpenAI WebRTC guide](https://developers.openai.com/api/docs/guides/realtime-webrtc)
for the upstream connection flow.
