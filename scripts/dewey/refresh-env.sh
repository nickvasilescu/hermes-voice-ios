#!/usr/bin/env bash
# Refresh bridge/.env on Dewey from local Hermes API key file + 1Password OPEN_AI_KEY.
# Writes secrets only under bridge/.env and /root/.hermes/voice_bridge_*. Never prints values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE="$ROOT/bridge"
ENV_FILE="$BRIDGE/.env"
HERMES_KEY_FILE="${HERMES_API_KEY_FILE:-/root/.hermes/voice_bridge_api_server_key}"
OPENAI_KEY_FILE="${OPENAI_API_KEY_FILE:-/root/.hermes/voice_bridge_openai_api_key}"

if [[ ! -f "$HERMES_KEY_FILE" ]]; then
  echo "missing Hermes API server key at $HERMES_KEY_FILE" >&2
  exit 1
fi

# Load OP service-account token from Hermes env without echoing it.
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" && -f /root/.hermes/.env ]]; then
  # shellcheck disable=SC1091
  set -a
  # Only export the one var we need.
  OP_SERVICE_ACCOUNT_TOKEN="$(python3 - <<'PY'
from pathlib import Path
for line in Path("/root/.hermes/.env").read_text().splitlines():
    if line.startswith("OP_SERVICE_ACCOUNT_TOKEN="):
        print(line.split("=", 1)[1])
        break
PY
)"
  export OP_SERVICE_ACCOUNT_TOKEN
  set +a
fi

OPENAI_KEY=""
if command -v op >/dev/null 2>&1 && [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  if OPENAI_KEY="$(op item get "Hermes Agent Secrets" --vault Dewey --fields OPEN_AI_KEY --reveal 2>/dev/null)"; then
    OPENAI_KEY="$(printf '%s' "$OPENAI_KEY" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  else
    OPENAI_KEY=""
  fi
fi

if [[ -z "$OPENAI_KEY" && -f "$OPENAI_KEY_FILE" ]]; then
  OPENAI_KEY="$(tr -d '\r\n' <"$OPENAI_KEY_FILE")"
fi

HERMES_KEY="$(tr -d '\r\n' <"$HERMES_KEY_FILE")"

{
  echo "NODE_ENV=development"
  echo "PORT=8787"
  echo "HERMES_API_BASE_URL=http://127.0.0.1:8642"
  echo "HERMES_API_KEY=${HERMES_KEY}"
  echo "BRIDGE_CORS_ALLOWLIST="
  echo "OPENAI_REALTIME_MODEL=gpt-realtime-2.1"
  if [[ -n "$OPENAI_KEY" ]]; then
    echo "OPENAI_API_KEY=${OPENAI_KEY}"
    echo "BRIDGE_MOCK_OPENAI=0"
    printf '%s\n' "$OPENAI_KEY" >"$OPENAI_KEY_FILE"
    chmod 600 "$OPENAI_KEY_FILE"
    echo "openai=live (from 1Password OPEN_AI_KEY or key file)" >&2
  else
    echo "BRIDGE_MOCK_OPENAI=1"
    echo "openai=mock (no OPEN_AI_KEY in 1Password / key file)" >&2
  fi
} >"$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE" >&2
