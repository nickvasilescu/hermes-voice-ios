#!/usr/bin/env bash
# Start/restart the bridge. Prefer Supervisor when installed; retain a
# bounded fallback for first deployment only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="${HERMES_VOICE_BRIDGE_LOG:-/tmp/hermes-voice-bridge.log}"
PID_FILE="${HERMES_VOICE_BRIDGE_PID:-/tmp/hermes-voice-bridge.pid}"
PORT="${PORT:-8787}"

bash "$(dirname "$0")/refresh-env.sh"

if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status hermes-voice-bridge >/dev/null 2>&1; then
  supervisorctl restart hermes-voice-bridge
else
  echo "warning: Supervisor entry absent; using temporary nohup fallback" >&2
  if [[ -f "$PID_FILE" ]]; then
    old="$(tr -cd '0-9' <"$PID_FILE")"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      kill "$old"
      for _ in $(seq 1 40); do
        kill -0 "$old" 2>/dev/null || break
        sleep 0.25
      done
    fi
  fi
  nohup "$ROOT/scripts/dewey/run-bridge.sh" >>"$LOG" 2>&1 &
  printf '%s\n' "$!" >"$PID_FILE"
fi

for _ in $(seq 1 80); do
  if curl -sf "http://127.0.0.1:${PORT}/v1/health" >/dev/null; then
    echo "bridge healthy on loopback:${PORT}"
    exit 0
  fi
  sleep 0.25
done

echo "bridge failed to become healthy" >&2
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl status hermes-voice-bridge >&2 || true
fi
tail -n 40 "$LOG" >&2 2>/dev/null || true
exit 1
