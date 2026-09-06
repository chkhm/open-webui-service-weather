#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Append the tool-server connections declared in docker-compose.yml to the
# ones stored in Open WebUI's database, then restart open-webui so it
# re-reads them.
#
#   ./scripts/sync-tool-servers.sh                 apply
#   ./scripts/sync-tool-servers.sh --dry-run       show what would be added
#   ./scripts/sync-tool-servers.sh --remove URL    delete the stored connection
#                                                  with this url, e.g. after
#                                                  removing a service
#
# Why this exists: TOOL_SERVER_CONNECTIONS only seeds an EMPTY database. Once
# Open WebUI has stored the connections -- which it does on first start, and
# again whenever they are saved in the admin UI -- the stored value wins and
# later changes to the environment variable are ignored. Adding a service to
# an existing install therefore needs the new connection written to the
# database. This does that without the admin UI.
#
# Entries are matched by url. Existing entries are never modified or
# reordered: Open WebUI identifies a tool server by its position in the
# array, so reordering would change tool ids. For the same reason --remove
# shifts the ids of every entry that came after the removed one.

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

# The desired list comes from the rendered compose config, so .env
# substitution and YAML folding have already been applied.
desired=$(docker compose config --format json 2>/dev/null | python3 -c '
import sys, json
cfg = json.load(sys.stdin)
env = cfg["services"]["open-webui"].get("environment", {})
print(env.get("TOOL_SERVER_CONNECTIONS", "[]"))')

# Merge (or remove) inside the container, which has the database and sqlite3.
result=$(docker exec -i -e DESIRED="$desired" -e DRY_RUN="$dry_run" -e REMOVE_URL="$remove_url" open-webui python3 - <<'PY'
import json, os, sqlite3, sys, time

desired = json.loads(os.environ["DESIRED"])
remove_url = os.environ.get("REMOVE_URL", "")
c = sqlite3.connect("/app/backend/data/webui.db")
rows = list(c.execute("select value from config where key='tool_server.connections'"))
stored = []
if rows:
    v = rows[0][0]
    stored = json.loads(v) if isinstance(v, str) else v

print("STORED " + str(len(stored)))

if remove_url:
    keep = [x for x in stored if x.get("url") != remove_url]
    if len(keep) == len(stored):
        print("NOT_STORED " + remove_url)
        sys.exit(1)
    print("REMOVE " + remove_url)
    merged = keep
else:
    have = {x.get("url") for x in stored}
    new = [x for x in desired if x.get("url") not in have]
    for x in new:
        print("ADD " + str(x.get("url")) + "  (" + x.get("info", {}).get("name", "") + ")")
    if not new:
        print("NOTHING_TO_ADD")
        sys.exit(0)
    if os.environ.get("DRY_RUN") == "true":
        print("DRY_RUN")
        sys.exit(0)
    merged = stored + new

now = int(time.time())
if rows:
    c.execute("update config set value=?, updated_at=? where key='tool_server.connections'",
              (json.dumps(merged), now))
else:
    c.execute("insert into config (key, value, updated_at) values (?, ?, ?)",
              ("tool_server.connections", json.dumps(merged), now))
c.commit()
print("WRITTEN " + str(len(merged)))
PY
)

printf '%s\n' "$result" | grep -E '^(STORED|ADD|REMOVE) ' | sed 's/^STORED /stored connections: /; s/^ADD /  + /; s/^REMOVE /  - /'

case "$result" in
    *NOT_STORED*)
        echo "no stored connection with url ${remove_url}; nothing removed" >&2
        exit 1 ;;
    *NOTHING_TO_ADD*)
        echo "nothing to add: every connection in docker-compose.yml is already stored"
        exit 0 ;;
    *DRY_RUN*)
        echo "(dry run, nothing written)"
        exit 0 ;;
    *WRITTEN*)
        total=$(printf '%s\n' "$result" | sed -n 's/^WRITTEN //p')
        echo "written: ${total} connection(s) now stored" ;;
    *)
        echo "unexpected result from the merge step:" >&2
        printf '%s\n' "$result" >&2
        exit 1 ;;
esac

echo "restarting open-webui so it re-reads the stored connections..."
docker compose restart open-webui >/dev/null 2>&1
for _ in $(seq 1 40); do
    st=$(docker inspect open-webui --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
    [ "$st" = "healthy" ] && break
    sleep 3
done
line=$(docker logs open-webui 2>&1 | grep -E 'Initialized [0-9]+ tool server' | tail -1 | sed 's/.*- //')
echo "open-webui: ${line:-did not report tool server initialisation (check docker compose logs open-webui)}"
if [ -z "$remove_url" ]; then
    echo
    echo "the new tool is registered; it still has to be switched on per chat under the wrench icon"
fi
