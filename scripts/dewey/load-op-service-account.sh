#!/usr/bin/env bash
# Source this file to load the 1Password service-account bootstrap without
# echoing it. The dedicated root-only file is the target. Reading the old
# Hermes .env is a temporary compatibility path removed by Phase 3.

if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

OP_TOKEN_FILE="${OP_SERVICE_ACCOUNT_TOKEN_FILE:-/root/.config/hermes-secrets/op-service-account-token}"
if [[ -f "$OP_TOKEN_FILE" ]]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(tr -d '\r\n' <"$OP_TOKEN_FILE")"
elif [[ -f /root/.hermes/.env ]]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(python3 - <<'PY'
from pathlib import Path
for line in Path('/root/.hermes/.env').read_text().splitlines():
    if line.startswith('OP_SERVICE_ACCOUNT_TOKEN='):
        print(line.split('=', 1)[1])
        break
PY
)"
  echo "warning: using transitional OP token source /root/.hermes/.env" >&2
else
  echo "missing 1Password service-account bootstrap" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
  echo "1Password service-account bootstrap is empty" >&2
  return 1 2>/dev/null || exit 1
fi
export OP_SERVICE_ACCOUNT_TOKEN
