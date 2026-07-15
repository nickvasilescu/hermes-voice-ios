#!/usr/bin/env bash
# Production-safe public smoke: health, closed bootstrap, authenticated
# session, harmless Hermes task, and live Realtime mint. No credential value
# or prefix is printed.
set -euo pipefail
umask 077

BASE_URL="${BRIDGE_BASE_URL:-https://dewey-bridge.momentumclaw.app}"
BOOTSTRAP_REF="${HERMES_VOICE_BOOTSTRAP_REF:-op://Dewey/Hermes Voice Bridge/BRIDGE_BOOTSTRAP_SECRET}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -z "${BRIDGE_BOOTSTRAP_SECRET:-}" ]]; then
  source "$(dirname "$0")/load-op-service-account.sh"
  BRIDGE_BOOTSTRAP_SECRET="$(op read "$BOOTSTRAP_REF")"
fi
if [[ -z "$BRIDGE_BOOTSTRAP_SECRET" ]]; then
  echo "bootstrap credential unavailable" >&2
  exit 1
fi

echo "health via $BASE_URL"
curl -sf "$BASE_URL/v1/health" >"$TMP/health.json"
python3 - "$TMP/health.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
assert body.get('ok') is True, body
print('HEALTH_OK')
PY

UNAUTH_CODE="$(curl -sS -o "$TMP/unauth.json" -w '%{http_code}' -X POST "$BASE_URL/v1/session" -H 'content-type: application/json' -d '{}')"
[[ "$UNAUTH_CODE" == "401" ]] || { echo "expected unauthenticated bootstrap 401, got $UNAUTH_CODE" >&2; exit 1; }
echo "BOOTSTRAP_CLOSED_OK"

printf 'header = "authorization: Bearer %s"\n' "$BRIDGE_BOOTSTRAP_SECRET" |
  curl -sf --config - -X POST "$BASE_URL/v1/session" -H 'content-type: application/json' -d '{}' >"$TMP/session.json"
TOKEN="$(python3 - "$TMP/session.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
token = body.get('sessionToken')
assert isinstance(token, str) and token.startswith('st_')
print(token)
PY
)"
echo "SESSION_OK"

printf 'header = "authorization: Bearer %s"\n' "$TOKEN" |
  curl -sf --config - -X POST "$BASE_URL/v1/tasks" -H 'content-type: application/json' \
    -d '{"instruction":"Reply with exactly the word PONG and nothing else."}' >"$TMP/task.json"
TID="$(python3 - "$TMP/task.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
task_id = body.get('id')
assert isinstance(task_id, str) and task_id.startswith('task_')
print(task_id)
PY
)"

FINAL=""
for i in $(seq 1 90); do
  printf 'header = "authorization: Bearer %s"\n' "$TOKEN" |
    curl -sf --config - "$BASE_URL/v1/tasks/$TID" >"$TMP/task-current.json"
  ST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP/task-current.json")"
  echo "task poll $i $ST"
  if [[ "$ST" == "completed" || "$ST" == "failed" || "$ST" == "canceled" ]]; then
    FINAL="$TMP/task-current.json"
    break
  fi
  sleep 1
done
[[ -n "$FINAL" ]] || { echo "task did not reach terminal state" >&2; exit 1; }
python3 - "$FINAL" <<'PY'
import json, sys
task = json.load(open(sys.argv[1]))
assert task['status'] == 'completed', task.get('status')
assert 'PONG' in (task.get('summary') or ''), 'expected PONG summary'
print('TASK_OK')
PY

printf 'header = "authorization: Bearer %s"\n' "$TOKEN" |
  curl -sS --config - -o "$TMP/realtime.json" -w '%{http_code}' -X POST \
    "$BASE_URL/v1/realtime/session" -H 'content-type: application/json' -d '{}' >"$TMP/realtime.code"
python3 - "$TMP/realtime.code" "$TMP/realtime.json" <<'PY'
import json, sys
code = open(sys.argv[1]).read().strip()
body = json.load(open(sys.argv[2]))
assert code == '200', (code, body.get('error'))
value = (body.get('clientSecret') or {}).get('value')
assert isinstance(value, str) and value.startswith('ek_'), 'live Realtime credential missing'
print('REALTIME_LIVE_OK')
PY

echo "SMOKE_DONE"
