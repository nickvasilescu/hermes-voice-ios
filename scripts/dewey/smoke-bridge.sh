#!/usr/bin/env bash
# Smoke the public Dewey bridge tunnel end-to-end (health → session → task → realtime).
set -euo pipefail

BASE_URL="${BRIDGE_BASE_URL:-https://dewey-bridge.momentumclaw.app}"

echo "health via $BASE_URL"
curl -sf "$BASE_URL/v1/health"
echo

SESSION="$(curl -sf -X POST "$BASE_URL/v1/session" -H 'content-type: application/json' -d '{}')"
TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionToken"])' <<<"$SESSION")"
echo "session minted"

TASK="$(curl -sf -X POST "$BASE_URL/v1/tasks" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"instruction":"Reply with exactly the word PONG and nothing else."}')"
TID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$TASK")"
echo "task $TID"

FINAL=""
for i in $(seq 1 90); do
  CUR="$(curl -sf -H "authorization: Bearer $TOKEN" "$BASE_URL/v1/tasks/$TID")"
  ST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$CUR")"
  echo "poll $i $ST"
  if [[ "$ST" == "completed" || "$ST" == "failed" || "$ST" == "canceled" ]]; then
    FINAL="$CUR"
    break
  fi
  sleep 1
done

python3 -c 'import json,sys; t=json.loads(sys.argv[1]); assert t["status"]=="completed", t; assert "PONG" in (t.get("summary") or ""), t; print("TASK_OK")' "$FINAL"

RT_CODE="$(curl -sS -o /tmp/rt.json -w '%{http_code}' -X POST "$BASE_URL/v1/realtime/session" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{}')"
echo "realtime_http=$RT_CODE"
python3 - <<PY
import json
from pathlib import Path
body = json.loads(Path("/tmp/rt.json").read_text())
print("realtime_http", "$RT_CODE")
secret = None
if isinstance(body, dict):
    cs = body.get("clientSecret") or {}
    secret = cs.get("value") if isinstance(cs, dict) else None
    print("realtime_error", body.get("error"))
    print("realtime_secret_prefix", (secret or "")[:12])
if secret and str(secret).startswith("ek_"):
    print("REALTIME_LIVE_OK")
elif secret and str(secret).startswith("mock_ek_"):
    print("REALTIME_MOCK_OK (set OPENAI_API_KEY on Dewey for live mint)")
else:
    print("REALTIME_NOT_OK", body)
    raise SystemExit(2)
print("SMOKE_DONE")
PY
