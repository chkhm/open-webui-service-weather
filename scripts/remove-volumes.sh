#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Delete this project's Docker volumes. THIS DESTROYS DATA.
#
#   ./scripts/remove-volumes.sh                 removes the Open WebUI data volume
#   ./scripts/remove-volumes.sh --with-models   also removes the Ollama model volume
#
# The data volume holds your admin account, chat history and settings -- and the
# tool-server connection record. Losing it is recoverable: compose reseeds that
# connection from TOOL_SERVER_CONNECTIONS on the next start, but you will have to
# create your account again.
#
# The model volume is tens of gigabytes and everything in it must be downloaded
# again, so it is only touched when you explicitly ask.

set -euo pipefail

cd "$(dirname "$0")/.."

with_models=false
case "${1:-}" in
    "")             ;;
    --with-models)  with_models=true ;;
    -h|--help)      awk 'NR==1 && /^#!/ {next}
                         /^#/ {sub(/^# ?/, "");
                               if ($0 !~ /^(SPDX-|Copyright )/) print; next}
                         {exit}' "$0"; exit 0 ;;
    *)              echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

# Resolve the real volume names from the compose file, so this keeps working if
# they are ever renamed there.
resolve() {
    docker compose config --format json \
        | python3 -c "import sys, json; v = json.load(sys.stdin)['volumes']; print(v['$1'].get('name', '$1'))"
}

targets=("$(resolve open-webui)")
$with_models && targets+=("$(resolve open-webui-ollama)")

running=$(docker compose ps --quiet 2>/dev/null | wc -l | tr -d ' ')
if [ "$running" != "0" ]; then
    echo "Containers are still running. Remove them first:" >&2
    echo "  ./scripts/remove-containers.sh" >&2
    exit 1
fi

echo "About to permanently delete:"
for v in "${targets[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
        size=$(docker run --rm -v "$v":/d busybox du -sh /d 2>/dev/null | cut -f1)
        printf '  %-40s %s\n' "$v" "$size"
    else
        printf '  %-40s (does not exist, skipping)\n' "$v"
    fi
done
$with_models || echo $'\nThe Ollama model volume is NOT included. Add --with-models to remove it too.'

echo
read -r -p 'Type "delete" to confirm: ' reply
if [ "$reply" != "delete" ]; then
    echo "Aborted, nothing was removed."
    exit 1
fi

for v in "${targets[@]}"; do
    docker volume rm "$v" >/dev/null 2>&1 && echo "removed $v" || echo "skipped $v"
done

echo
echo "This project's volumes now:"
for key in open-webui open-webui-ollama; do
    v=$(resolve "$key")
    if docker volume inspect "$v" >/dev/null 2>&1; then
        printf '  %-40s present\n' "$v"
    else
        printf '  %-40s gone\n' "$v"
    fi
done
