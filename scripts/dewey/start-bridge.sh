#!/usr/bin/env bash
# Start (or restart) the Hermes Voice bridge on Dewey for the Cloudflare tunnel
# hostname dewey-bridge.momentumclaw.app → http://127.0.0.1:8787.
#
# Safe to re-run. Secrets stay in bridge/.env (gitignored) on the host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE="$ROOT/bridge"
ENV_FILE="$BRIDGE/.env"
LOG="${HERMES_VOICE_BRIDGE_LOG:-/tmp/hermes-voice-bridge.log}"
PID_FILE="${HERMES_VOICE_BRIDGE_PID:-/tmp/hermes-voice-bridge.pid}"
PORT="${PORT:-8787}"

export PATH="${HOME}/.hermes/node/bin:/usr/local/bin:${PATH}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE — copy from .env.example and fill secrets" >&2
  exit 1
fi

# Stop previous bridge if we own the pidfile / port.
if [[ -f "$PID_FILE" ]]; then
  old="$(cat "$PID_FILE" || true)"
  if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
    kill "$old" || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
else
  # Portable fallback: kill node listeners on PORT.
  python3 - "$PORT" <<'PY' || true
import os, signal, sys
port = sys.argv[1]
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except Exception:
        continue
    # cheap heuristic via cmdline
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", "ignore")
    except Exception:
        continue
    if "src/server.ts" in cmd or "dist/server.js" in cmd:
        os.kill(int(pid), signal.SIGTERM)
PY
fi
sleep 1

cd "$BRIDGE"
# Ensure deps
if [[ ! -d node_modules ]]; then
  npm install
fi

nohup node --env-file-if-exists=.env --import tsx src/server.ts >>"$LOG" 2>&1 &
echo $! >"$PID_FILE"
echo "started pid=$(cat "$PID_FILE") port=$PORT log=$LOG"

for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:${PORT}/v1/health" >/dev/null; then
    curl -sf "http://127.0.0.1:${PORT}/v1/health"
    echo
    exit 0
  fi
  sleep 0.25
done

echo "bridge failed to become healthy; last log lines:" >&2
tail -n 40 "$LOG" >&2 || true
exit 1
