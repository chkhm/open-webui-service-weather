#!/usr/bin/env bash
#
# Verify the whole weather-tool chain, from containers up to a live forecast.
#
# Every failure this project has hit was silent: the model simply answered that
# it could not look up the weather, with nothing in the logs. Each check below
# corresponds to one of those failures.
#
# Exits 0 if everything passes, 1 otherwise.

set -uo pipefail

cd "$(dirname "$0")/.."

failures=0

ok()   { printf '  [ ok ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); }
note() { printf '         %s\n' "$1"; }

echo "1. containers"
for c in open-webui weather-proxy; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
        ok "$c is running"
    else
        fail "$c is not running"
        note "start the stack with: docker compose up -d"
    fi
done
if [ "$failures" -ne 0 ]; then
    echo
    echo "containers are down, skipping the remaining checks"
    exit 1
fi

echo "2. OpenWeather credentials"
key=$(docker exec weather-proxy printenv OWM_API_KEY 2>/dev/null || true)
if [ -n "$key" ]; then
    ok "OWM_API_KEY is set in weather-proxy (${#key} characters)"
else
    fail "OWM_API_KEY is empty or unset in weather-proxy"
    note "check .env in the repository root, then: docker compose up -d"
fi

echo "3. OpenAPI spec"
code=$(docker exec open-webui curl -s -o /tmp/spec.json -w '%{http_code}' \
       http://weather-proxy:5005/openapi.json 2>/dev/null || true)
if [ "$code" = "200" ]; then
    op=$(docker exec open-webui python3 -c \
        "import json; print(json.load(open('/tmp/spec.json'))['paths']['/weather']['post']['operationId'])" 2>/dev/null || true)
    if [ -n "$op" ]; then
        ok "spec served at /openapi.json, operationId = $op"
    else
        fail "spec is served but has no operationId at paths./weather.post"
        note "Open WebUI derives the tool name from operationId"
    fi
else
    fail "GET http://weather-proxy:5005/openapi.json returned $code"
    note "the proxy must serve an OpenAPI document for the tool to register"
fi

echo "4. stored tool-server connection"
url=$(docker exec open-webui python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = list(c.execute(\"select value from config where key='tool_server.connections'\"))
if not r:
    print('')
else:
    v = r[0][0]
    n = json.loads(v) if isinstance(v, str) else v
    print(n[0]['url'] if n else '')
" 2>/dev/null || true)
if [ -z "$url" ]; then
    fail "no tool-server connection stored in webui.db"
    note "it is seeded from TOOL_SERVER_CONNECTIONS on a fresh volume"
elif [ "${url%/weather}" != "$url" ]; then
    fail "connection points at $url"
    note "it must point at the proxy root, otherwise the spec resolves to /weather/openapi.json"
else
    ok "connection points at $url"
fi

echo "5. Open WebUI resolves the tool"
resolved=$(docker exec -e PYTHONPATH=/app/backend -e WEBUI_SECRET_KEY=health-check -i open-webui python - <<'PY' 2>/dev/null
import asyncio, json, sqlite3
from open_webui.utils.tools import get_tool_servers_data

c = sqlite3.connect("/app/backend/data/webui.db")
rows = list(c.execute("select value from config where key='tool_server.connections'"))
raw = rows[0][0] if rows else "[]"
conns = json.loads(raw) if isinstance(raw, str) else raw

async def main():
    servers = await get_tool_servers_data(conns)
    print(",".join(s["name"] for srv in servers for s in srv["specs"]))

asyncio.run(main())
PY
)
resolved=$(printf '%s' "$resolved" | tail -1)
if [ -n "$resolved" ]; then
    ok "tools available to the model: $resolved"
else
    fail "Open WebUI resolved no tools from the connection"
    note "the connection exists but its spec could not be fetched or parsed"
fi

echo "6. live forecast"
entries=$(docker exec open-webui sh -c \
    "curl -s -X POST http://weather-proxy:5005/weather -H 'Content-Type: application/json' -d '{\"city\":\"Princeton\",\"state\":\"NJ\"}'" 2>/dev/null \
    | docker exec -i open-webui python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d['forecast']) if 'forecast' in d else 'ERROR:' + str(d.get('error'))[:80])
except Exception:
    print('ERROR:unparseable response')
" 2>/dev/null || true)
case "$entries" in
    ERROR:*) fail "live call failed: ${entries#ERROR:}"
             note "an unauthorized error usually means the API key is wrong or not yet activated" ;;
    ''|*[!0-9]*) fail "live call returned no usable forecast" ;;
    *)       ok "live call returned $entries forecast entries for Princeton, NJ" ;;
esac

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "$failures check(s) failed"
exit 1
