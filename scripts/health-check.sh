#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Verify every tool-service chain, from containers up to a live call.
#
# Every failure this project has hit was silent: the model simply answered that
# it could not do the thing, with nothing in the logs. Each check below
# corresponds to one of those failures.
#
# Adding a service: add its container to CONTAINERS, write a check_<name>_proxy
# function modelled on check_weather_proxy, call it in the main flow below, and
# add its operationId(s) to the check_resolved call.
#
# Exits 0 if everything passes, 1 otherwise.

set -uo pipefail

cd "$(dirname "$0")/.."

# Everything below talks to Docker. Say so plainly if the daemon is not here,
# instead of reporting healthy containers as "not running".
if ! docker info >/dev/null 2>&1; then
    echo "cannot reach the Docker daemon on $(hostname)" >&2
    echo "run this on the machine that hosts the stack" >&2
    exit 1
fi

# Containers that must be running. Add each new tool service here. The ollama
# container is only expected when the gpu profile is active (compose reads
# COMPOSE_PROFILES from .env); with a native Ollama there is none.
CONTAINERS=(open-webui weather-proxy currency-proxy)
if docker compose config --services 2>/dev/null | grep -qx ollama; then
    CONTAINERS+=(ollama)
fi

failures=0
section_no=0

ok()   { printf '  [ ok ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); }
note() { printf '         %s\n' "$1"; }
section() { section_no=$((section_no + 1)); echo "${section_no}. $1"; }

# --------------------------------------------------------------------------
# Reusable checks. All probes run from inside the open-webui container so
# that service names resolve exactly as they do for Open WebUI itself.
# --------------------------------------------------------------------------

# check_spec <container> <port> <path> <method>
# The service must serve an OpenAPI document at /openapi.json, and the given
# path/method must carry an operationId: that is the tool name the model sees.
check_spec() {
    local container=$1 port=$2 path=$3 method=$4
    local base="http://${container}:${port}"
    local code
    code=$(docker exec open-webui curl -s -o "/tmp/spec-${container}.json" -w '%{http_code}' \
           "${base}/openapi.json" 2>/dev/null || true)
    if [ "$code" != "200" ]; then
        fail "GET ${base}/openapi.json returned ${code:-no response}"
        note "the service must serve an OpenAPI document for the tool to register"
        return
    fi
    local op
    op=$(docker exec open-webui python3 -c "
import json
d = json.load(open('/tmp/spec-${container}.json'))
print(d['paths']['${path}']['${method}']['operationId'])" 2>/dev/null || true)
    if [ -n "$op" ]; then
        ok "${container} serves /openapi.json, operationId = ${op}"
    else
        fail "${container} spec has no operationId at paths.${path}.${method}"
        note "Open WebUI derives the tool name from operationId"
    fi
}

# check_connection <url>
# A tool-server connection with exactly this url must be stored in webui.db.
# The url must be the service ROOT: Open WebUI appends the spec path and the
# operation path to it, so a url ending in an endpoint resolves the spec to
# <endpoint>/openapi.json and fails.
check_connection() {
    local url=$1
    local result
    result=$(docker exec open-webui python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = list(c.execute(\"select value from config where key='tool_server.connections'\"))
conns = []
if r:
    v = r[0][0]
    conns = json.loads(v) if isinstance(v, str) else v
urls = [x.get('url', '') for x in conns]
url = '${url}'
if url in urls:
    print('FOUND')
else:
    deeper = [u for u in urls if u.startswith(url + '/')]
    print('SUBPATH:' + deeper[0] if deeper else 'MISSING:' + ','.join(urls))" 2>/dev/null || true)
    case "$result" in
        FOUND)
            ok "connection stored for ${url}" ;;
        SUBPATH:*)
            fail "connection points at ${result#SUBPATH:}"
            note "it must point at the service root ${url}, or the spec resolves under the endpoint" ;;
        MISSING:*)
            fail "no stored connection for ${url}"
            local have="${result#MISSING:}"
            note "stored: ${have:-none}"
            note "on an existing install run: ./scripts/sync-tool-servers.sh" ;;
        *)
            fail "could not read tool_server.connections from webui.db" ;;
    esac
}

# check_resolved <tool>...
# Run Open WebUI's own tool-server resolution against the stored connections
# and require every named tool to come back. This is what the model is
# actually offered.
check_resolved() {
    local resolved
    resolved=$(docker exec -e PYTHONPATH=/app/backend -e WEBUI_SECRET_KEY=health-check -i open-webui python - <<'PY' 2>/dev/null
import asyncio, json, sqlite3
from open_webui.utils.tools import get_tool_servers_data

c = sqlite3.connect("/app/backend/data/webui.db")
rows = list(c.execute("select value from config where key='tool_server.connections'"))
raw = rows[0][0] if rows else "[]"
conns = json.loads(raw) if isinstance(raw, str) else raw

async def main():
    servers = await get_tool_servers_data(conns)
    print("RESOLVED:" + ",".join(s["name"] for srv in servers for s in srv["specs"]))

asyncio.run(main())
PY
)
    resolved=$(printf '%s\n' "$resolved" | grep '^RESOLVED:' | tail -1)
    resolved=${resolved#RESOLVED:}
    if [ -z "$resolved" ]; then
        fail "Open WebUI resolved no tools from the stored connections"
        note "connections exist but their specs could not be fetched or parsed"
        return
    fi
    ok "tools available to the model: ${resolved}"
    local tool
    for tool in "$@"; do
        case ",${resolved}," in
            *",${tool},"*) ;;
            *) fail "expected tool '${tool}' was not resolved"
               note "check that its operationId is '${tool}' and that its connection is stored" ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Per-service checks
# --------------------------------------------------------------------------

check_weather_proxy() {
    section "weather-proxy: OpenWeather credentials"
    local key
    key=$(docker exec weather-proxy printenv OWM_API_KEY 2>/dev/null || true)
    if [ -n "$key" ]; then
        ok "OWM_API_KEY is set in weather-proxy (${#key} characters)"
    else
        fail "OWM_API_KEY is empty or unset in weather-proxy"
        note "check .env in the repository root, then: docker compose up -d"
    fi

    section "weather-proxy: OpenAPI spec"
    check_spec weather-proxy 5005 /weather post

    section "weather-proxy: stored connection"
    check_connection http://weather-proxy:5005

    section "weather-proxy: live forecast"
    local entries
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
}

check_currency_proxy() {
    section "currency-proxy: OpenAPI spec"
    check_spec currency-proxy 5006 /convert post

    section "currency-proxy: stored connection"
    check_connection http://currency-proxy:5006

    section "currency-proxy: live conversion"
    local result
    result=$(docker exec open-webui sh -c \
        "curl -s -X POST http://currency-proxy:5006/convert -H 'Content-Type: application/json' -d '{\"amount\":100,\"from_currency\":\"USD\",\"to_currency\":\"EUR\"}'" 2>/dev/null \
        | docker exec -i open-webui python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        print('ERROR:' + str(d['error'])[:80])
    else:
        print(str(d['converted_amount']) + ' EUR on ' + str(d['date']))
except Exception:
    print('ERROR:unparseable response')
" 2>/dev/null || true)
    case "$result" in
        ERROR:*) fail "live call failed: ${result#ERROR:}"
                 note "Frankfurter needs no key; a failure usually means no outbound internet from the container" ;;
        '')      fail "live call returned no usable result" ;;
        *)       ok "live call: 100 USD -> ${result}" ;;
    esac
}

# --------------------------------------------------------------------------
# Main flow
# --------------------------------------------------------------------------

section "containers"
for c in "${CONTAINERS[@]}"; do
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

section "model server"
# Probe whatever open-webui itself is configured to use, from inside open-webui,
# so a native Ollama and the container are checked the same way.
ollama_url=$(docker exec open-webui printenv OLLAMA_BASE_URL 2>/dev/null || true)
ollama_url=${ollama_url:-http://ollama:11434}
ver=$(docker exec open-webui curl -s --max-time 10 "${ollama_url}/api/version" 2>/dev/null \
      | docker exec -i open-webui python3 -c 'import sys,json; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)
if [ -n "$ver" ]; then
    ok "open-webui reaches ollama at ${ollama_url} (version $ver)"
    models=$(docker exec open-webui curl -s --max-time 10 "${ollama_url}/api/tags" 2>/dev/null \
        | docker exec -i open-webui python3 -c 'import sys,json; print(",".join(m["name"] for m in json.load(sys.stdin).get("models",[])))' 2>/dev/null || true)
    if [ -n "$models" ]; then
        ok "models available: $models"
    else
        fail "ollama is reachable but has no models"
        note "pull one with: ollama pull <model> (docker exec ollama ollama pull <model> under the gpu profile)"
    fi
else
    fail "open-webui cannot reach the model server at ${ollama_url}"
    if [ "$ollama_url" = "http://ollama:11434" ] && [ "$(docker inspect -f '{{.State.Running}}' ollama 2>/dev/null)" != "true" ]; then
        note "no ollama container is running: set COMPOSE_PROFILES=gpu in .env, or point OLLAMA_BASE_URL at a native Ollama"
    else
        note "check OLLAMA_BASE_URL in .env; for a native Ollama on this host use http://host.docker.internal:11434"
    fi
fi

check_weather_proxy
check_currency_proxy

section "Open WebUI resolves the tools"
check_resolved get_weather convert_currency

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "$failures check(s) failed"
exit 1
