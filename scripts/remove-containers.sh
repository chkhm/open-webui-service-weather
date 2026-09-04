#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Stop and remove this project's containers and its network.
# Volumes are left alone, so your Open WebUI account, chat history, tool
# configuration and downloaded models all survive. Bring things back with
# `docker compose up -d`.
#
# To delete the data as well, see remove-volumes.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "Removing containers and network for project: $(docker compose config --format json | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')"
echo

docker compose down --remove-orphans

echo
echo "Volumes were kept:"
for key in open-webui open-webui-ollama; do
    v=$(docker compose config --format json \
        | python3 -c "import sys, json; d = json.load(sys.stdin)['volumes']; print(d['$key'].get('name', '$key'))")
    printf '  %s\n' "$v"
done
echo
echo "Bring the stack back up with: docker compose up -d"
