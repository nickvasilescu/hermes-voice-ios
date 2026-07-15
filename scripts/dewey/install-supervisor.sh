#!/usr/bin/env bash
# Install/update Supervisor ownership for the voice bridge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/scripts/dewey/hermes-voice-bridge.supervisor.conf"
TARGET="/etc/supervisor/conf.d/hermes-voice-bridge.conf"

if [[ "$ROOT" != "/root/Desktop/repos/hermes-voice-ios" ]]; then
  echo "unexpected Dewey checkout path: $ROOT" >&2
  echo "update the Supervisor config deliberately instead of installing a stale path" >&2
  exit 1
fi

bash "$ROOT/scripts/dewey/refresh-env.sh"
install -o root -g root -m 0644 "$SOURCE" "$TARGET"
supervisorctl reread
supervisorctl update
supervisorctl status hermes-voice-bridge
