#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# Drive one question through the real model with the real tools, the way a
# chat would, and report which tools it called.
#
#   ./scripts/e2e-tool-call.sh --expect get_weather \
#       --question "What will the weather be this weekend in Princeton, NJ?"
#
# Options:
#   --question TEXT   the user message (required)
#   --expect TOOL     fail unless the model called this tool (repeatable)
#   --model NAME      Ollama model to use (default: gpt-oss:120b)
#
# Resolves every stored tool-server connection with Open WebUI's own code,
# offers ALL of their tools to the model through Ollama's chat API, executes
# each tool call through Open WebUI's execute_tool_server, feeds the result
# back, and loops until the model answers. Runs inside the open-webui
# container so service names resolve and Open WebUI's Python is available.
#
# This is not the chat UI: it does not exercise the wrench toggle or the
# frontend. It proves the model + spec + service chain, and that the model
# picks the right tool when several are on offer.
#
# Exits 0 when the model answered and every --expect tool was called.

set -uo pipefail

cd "$(dirname "$0")/.."

# Everything below talks to Docker. Say so plainly if the daemon is not here,
# instead of reporting healthy containers as "not running".
if ! docker info >/dev/null 2>&1; then
    echo "cannot reach the Docker daemon on $(hostname)" >&2
    echo "run this on the machine hosting the stack, e.g.:" >&2
    echo "  ssh spark01 'cd ~/git/open-webui-service-weather && ./scripts/e2e-tool-call.sh'" >&2
    exit 1
fi

model="gpt-oss:120b"
question=""
expect=""

while [ $# -gt 0 ]; do
    case "$1" in
        --question) question=${2:-}; shift 2 ;;
        --expect)   expect="${expect:+$expect,}${2:-}"; shift 2 ;;
        --model)    model=${2:-}; shift 2 ;;
        -h|--help)  awk 'NR==1 && /^#!/ {next}
                         /^#/ {sub(/^# ?/, "");
                               if ($0 !~ /^(SPDX-|Copyright )/) print; next}
                         {exit}' "$0"; exit 0 ;;
        *)          echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

if [ -z "$question" ]; then
    echo "--question is required (try --help)" >&2
    exit 2
fi

if [ "$(docker inspect -f '{{.State.Running}}' open-webui 2>/dev/null)" != "true" ]; then
    echo "open-webui is not running; start the stack first: docker compose up -d" >&2
    exit 1
fi

echo "model: ${model}"
echo "question: ${question}"
echo

docker exec -i \
    -e PYTHONPATH=/app/backend -e WEBUI_SECRET_KEY=e2e \
    -e E2E_MODEL="$model" -e E2E_QUESTION="$question" -e E2E_EXPECT="$expect" \
    open-webui python - <<'PY' 2>/dev/null | grep -vE 'WARNI|FutureWarning|warnings\.warn|CORS_ALLOW|alembic|USER_AGENT|grpc'
import asyncio, datetime, json, os, sqlite3, sys
import aiohttp
from open_webui.utils.tools import get_tool_servers_data, execute_tool_server

MODEL = os.environ["E2E_MODEL"]
QUESTION = os.environ["E2E_QUESTION"]
EXPECT = [x for x in os.environ.get("E2E_EXPECT", "").split(",") if x]
OLLAMA = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/") + "/api/chat"
MAX_ROUNDS = 8

c = sqlite3.connect("/app/backend/data/webui.db")
rows = list(c.execute("select value from config where key='tool_server.connections'"))
raw = rows[0][0] if rows else "[]"
conns = json.loads(raw) if isinstance(raw, str) else raw


async def main():
    servers = await get_tool_servers_data(conns)
    owner, tools = {}, []
    for srv in servers:
        for spec in srv["specs"]:
            owner[spec["name"]] = srv
            tools.append({"type": "function", "function": {
                "name": spec["name"],
                "description": spec["description"],
                "parameters": spec["parameters"],
            }})
    print("tools offered:", ", ".join(owner) if owner else "(none)")
    if not tools:
        print("FAIL: no tools resolved from the stored connections")
        sys.exit(2)

    # The chat UI injects the current date; mirror that so relative dates work.
    today = datetime.date.today()
    messages = [
        {"role": "system", "content": f"Current date: {today.isoformat()} ({today.strftime('%A')})."},
        {"role": "user", "content": QUESTION},
    ]
    called = []
    answered = False
    timeout = aiohttp.ClientTimeout(total=900)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        for rnd in range(1, MAX_ROUNDS + 1):
            async with session.post(OLLAMA, json={
                "model": MODEL, "messages": messages, "tools": tools, "stream": False,
            }) as r:
                body = await r.json()
            msg = body.get("message") or {}
            if not msg:
                print("FAIL: no message from the model:", json.dumps(body)[:300])
                sys.exit(1)
            messages.append(msg)
            calls = msg.get("tool_calls") or []
            if not calls:
                print(f"\nround {rnd}: model answered\n")
                print((msg.get("content") or msg.get("thinking") or "")[:1500])
                answered = True
                break
            for tc in calls:
                name = tc["function"]["name"]
                args = tc["function"]["arguments"]
                if isinstance(args, str):
                    args = json.loads(args)
                print(f"round {rnd}: {name} {json.dumps(args)}")
                called.append(name)
                srv = owner.get(name)
                if srv is None:
                    result = {"error": f"unknown tool {name}"}
                else:
                    result, _ = await execute_tool_server(
                        url=srv["url"], headers={}, cookies={},
                        name=name, params=args, server_data=srv,
                    )
                print("   ->", json.dumps(result)[:200])
                messages.append({"role": "tool", "content": json.dumps(result)})

    if not answered:
        print(f"\nFAIL: no final answer after {MAX_ROUNDS} rounds")
        sys.exit(1)
    missing = [t for t in EXPECT if t not in called]
    if missing:
        print(f"\nFAIL: expected tool(s) not called: {', '.join(missing)}")
        sys.exit(1)
    if EXPECT:
        print(f"\nexpected tool(s) called: {', '.join(EXPECT)}")


asyncio.run(main())
PY
exit "${PIPESTATUS[0]}"
