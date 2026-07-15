#!/usr/bin/env bash
# Supervisor entrypoint. Resolves 1Password references in memory and execs
# the bridge. Secret values never appear in files, command arguments, or logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE="$ROOT/bridge"
REFS_FILE="${HERMES_VOICE_ENV_REFS:-$BRIDGE/.env.refs}"
HERMES_KEY_FILE="${HERMES_API_KEY_FILE:-/root/.hermes/voice_bridge_api_server_key}"

export PATH="${HOME}/.hermes/node/bin:/usr/local/bin:${PATH}"
source "$(dirname "$0")/load-op-service-account.sh"

if [[ ! -f "$REFS_FILE" ]]; then
  bash "$(dirname "$0")/refresh-env.sh"
fi
if [[ ! -s "$HERMES_KEY_FILE" ]]; then
  echo "missing Hermes API server key" >&2
  exit 1
fi

HERMES_API_KEY="$(tr -d '\r\n' <"$HERMES_KEY_FILE")"
export HERMES_API_KEY

cd "$BRIDGE"
exec op run --env-file="$REFS_FILE" -- node --import tsx src/server.ts
