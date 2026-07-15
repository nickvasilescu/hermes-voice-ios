#!/usr/bin/env bash
# Render the non-secret bridge environment plus 1Password references.
# No resolved credential is written to disk or printed.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REFS_FILE="${HERMES_VOICE_ENV_REFS:-$ROOT/bridge/.env.refs}"
OPENAI_REF="${HERMES_VOICE_OPENAI_REF:-op://Dewey/Hermes Agent Secrets/OPEN_AI_KEY}"
BOOTSTRAP_REF="${HERMES_VOICE_BOOTSTRAP_REF:-op://Dewey/Hermes Voice Bridge/BRIDGE_BOOTSTRAP_SECRET}"

{
  printf '%s\n' 'NODE_ENV=production'
  printf '%s\n' 'HOST=127.0.0.1'
  printf '%s\n' 'PORT=8787'
  printf '%s\n' 'HERMES_API_BASE_URL=http://127.0.0.1:8642'
  printf '%s\n' 'BRIDGE_CORS_ALLOWLIST='
  printf '%s\n' 'OPENAI_REALTIME_MODEL=gpt-realtime-2.1'
  printf '%s\n' 'BRIDGE_MOCK_OPENAI=0'
  printf 'OPENAI_API_KEY=%s\n' "$OPENAI_REF"
  printf 'BRIDGE_BOOTSTRAP_SECRET=%s\n' "$BOOTSTRAP_REF"
} >"$REFS_FILE"
chmod 600 "$REFS_FILE"

echo "wrote redacted reference environment $REFS_FILE" >&2
echo "resolved values were not written" >&2
