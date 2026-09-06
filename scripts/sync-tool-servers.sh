#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Reconcile what docker-compose.yml declares with what Open WebUI has stored
# in its database, then restart open-webui so it re-reads the result:
#
#   - tool-server connections (TOOL_SERVER_CONNECTIONS): missing ones are
#     appended; existing ones are never modified or reordered
#   - the Ollama url (OLLAMA_BASE_URL): replaced when the stored value differs
#
#   ./scripts/sync-tool-servers.sh                 apply
#   ./scripts/sync-tool-servers.sh --dry-run       show what would change
#   ./scripts/sync-tool-servers.sh --remove URL    delete the stored tool-server
#                                                  connection with this url,
#                                                  e.g. after removing a service
#
# Why this exists: both environment variables only seed an EMPTY database. Once
# Open WebUI has stored a value -- which it does on first start, and again
# whenever it is saved in the admin UI -- the stored value wins and later
# changes to .env are ignored. Adding a service, or changing where Ollama runs,
# on an existing install therefore needs the database updated. This does that
# without the admin UI.
#
# Tool servers are matched by url. Open WebUI identifies a tool server by its
# position in the array, so entries are never reordered, and --remove shifts
# the ids of every entry after the removed one. The Ollama url is only
# replaced when exactly one is stored; a hand-curated list of several is left
# alone and reported.

set -euo pipefail

cd "$(dirname "$0")/.."

# Everything below talks to Docker. Say so plainly if the daemon is not here,
# instead of reporting healthy containers as "not running".
if ! docker info >/dev/null 2>&1; then
    echo "cannot reach the Docker daemon on $(hostname)" >&2
    echo "run this on the machine that hosts the stack" >&2
    exit 1
fi

dry_run=false
remove_url=""
case "${1:-}" in
    "")         ;;
    --dry-run)  dry_run=true ;;
    --remove)   remove_url=${2:-}
                if [ -z "$remove_url" ]; then echo "--remove needs a url (try --help)" >&2; exit 2; fi ;;
    -h|--help)  awk 'NR==1 && /^#!/ {next}
                     /^#/ {sub(/^# ?/, "");
                           if ($0 !~ /^(SPDX-|Copyright )/) print; next}
                     {exit}' "$0"; exit 0 ;;
    *)          echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

if [ "$(docker inspect -f '{{.State.Running}}' open-webui 2>/dev/null)" != "true" ]; then
    echo "open-webui is not running; start the stack first: docker compose up -d" >&2
    exit 1
fi

# The desired values come from the rendered compose config, so .env
# substitution and YAML folding have already been applied.
rendered=$(docker compose config --format json 2>/dev/null)
desired=$(printf '%s' "$rendered" | python3 -c '
import sys, json
env = json.load(sys.stdin)["services"]["open-webui"].get("environment", {})
print(env.get("TOOL_SERVER_CONNECTIONS", "[]"))')
desired_ollama=$(printf '%s' "$rendered" | python3 -c '
import sys, json
env = json.load(sys.stdin)["services"]["open-webui"].get("environment", {})
print(env.get("OLLAMA_BASE_URL", ""))')

# Reconcile inside the container, which has the database and sqlite3.
result=$(docker exec -i -e DESIRED="$desired" -e DESIRED_OLLAMA="$desired_ollama" \
         -e DRY_RUN="$dry_run" -e REMOVE_URL="$remove_url" open-webui python3 - <<'PY'
import json, os, sqlite3, sys, time

desired = json.loads(os.environ["DESIRED"])
desired_ollama = os.environ.get("DESIRED_OLLAMA", "")
remove_url = os.environ.get("REMOVE_URL", "")
dry_run = os.environ.get("DRY_RUN") == "true"

c = sqlite3.connect("/app/backend/data/webui.db")

def load(key):
    rows = list(c.execute("select value from config where key=?", (key,)))
    if not rows:
        return None
    v = rows[0][0]
    return json.loads(v) if isinstance(v, str) else v

def store(key, value):
    now = int(time.time())
    if list(c.execute("select 1 from config where key=?", (key,))):
        c.execute("update config set value=?, updated_at=? where key=?", (json.dumps(value), now, key))
    else:
        c.execute("insert into config (key, value, updated_at) values (?, ?, ?)", (key, json.dumps(value), now))

stored = load("tool_server.connections") or []
print("STORED " + str(len(stored)))

writes = []

if remove_url:
    keep = [x for x in stored if x.get("url") != remove_url]
    if len(keep) == len(stored):
        print("NOT_STORED " + remove_url)
        sys.exit(1)
    print("REMOVE " + remove_url)
    writes.append(("tool_server.connections", keep))
else:
    have = {x.get("url") for x in stored}
    new = [x for x in desired if x.get("url") not in have]
    for x in new:
        print("ADD " + str(x.get("url")) + "  (" + x.get("info", {}).get("name", "") + ")")
    if new:
        writes.append(("tool_server.connections", stored + new))

    # The Ollama url: seeded from the environment on first start, stored
    # thereafter. Replace a single stored url that drifted from .env; leave a
    # hand-curated list of several alone.
    stored_ollama = load("ollama.base_urls")
    if desired_ollama and stored_ollama:
        if len(stored_ollama) == 1 and stored_ollama[0] != desired_ollama:
            print("OLLAMA " + stored_ollama[0] + " -> " + desired_ollama)
            writes.append(("ollama.base_urls", [desired_ollama]))
        elif len(stored_ollama) > 1 and desired_ollama not in stored_ollama:
            print("OLLAMA_MANUAL " + ",".join(stored_ollama))

if not writes:
    print("NOTHING_TO_DO")
    sys.exit(0)
if dry_run:
    print("DRY_RUN")
    sys.exit(0)

for key, value in writes:
    store(key, value)
c.commit()
print("WRITTEN " + ",".join(k for k, _ in writes))
PY
)

printf '%s\n' "$result" | grep -E '^(STORED|ADD|REMOVE|OLLAMA) ' \
    | sed 's/^STORED /stored connections: /; s/^ADD /  + /; s/^REMOVE /  - /; s/^OLLAMA /  ollama url: /'
if printf '%s\n' "$result" | grep -q '^OLLAMA_MANUAL '; then
    echo "  ollama urls stored: $(printf '%s\n' "$result" | sed -n 's/^OLLAMA_MANUAL //p')"
    echo "  several are stored and none is ${desired_ollama}; not touching them -- edit under Admin Panel > Settings > Connections"
fi

case "$result" in
    *NOT_STORED*)
        echo "no stored connection with url ${remove_url}; nothing removed" >&2
        exit 1 ;;
    *NOTHING_TO_DO*)
        echo "nothing to do: stored connections and Ollama url already match docker-compose.yml"
        exit 0 ;;
    *DRY_RUN*)
        echo "(dry run, nothing written)"
        exit 0 ;;
    *WRITTEN*)
        echo "written: $(printf '%s\n' "$result" | sed -n 's/^WRITTEN //p')" ;;
    *)
        echo "unexpected result from the reconcile step:" >&2
        printf '%s\n' "$result" >&2
        exit 1 ;;
esac

echo "restarting open-webui so it re-reads the stored values..."
docker compose restart open-webui >/dev/null 2>&1
for _ in $(seq 1 40); do
    st=$(docker inspect open-webui --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
    [ "$st" = "healthy" ] && break
    sleep 3
done
line=$(docker logs open-webui 2>&1 | grep -E 'Initialized [0-9]+ tool server' | tail -1 | sed 's/.*- //')
echo "open-webui: ${line:-did not report tool server initialisation (check docker compose logs open-webui)}"
if [ -z "$remove_url" ] && printf '%s\n' "$result" | grep -q '^ADD '; then
    echo
    echo "the new tool is registered; it still has to be switched on per chat under the wrench icon"
fi
