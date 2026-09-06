# Deploy and verify

Two situations, decided at intake. In both, the user merges and pushes; do not commit on
their behalf, and never copy `.env` anywhere — it holds the real secrets.

## Local: the stack runs on this machine

The common case. Four commands, all from the repository root:

```bash
docker compose up -d --build          # recreates open-webui: its environment changed
./scripts/sync-tool-servers.sh        # existing install: write the new connection to webui.db
./scripts/health-check.sh             # every section green; the last line names the new tool
./scripts/e2e-tool-call.sh --expect <operationId> --question "<a question that demands live data>"
```

Then the chat window (step 5 below).

## Remote: the stack runs on a host reachable by ssh

Set `HOST` and `REPO` to what the user gave at intake (for example `spark01` and
`~/git/open-webui-service-weather`).

### 1. Sync the working tree

Copy only what changed. Never copy `.git` or `.env`.

```bash
rsync -av --exclude .git --exclude .env --exclude '__pycache__' ./ "$HOST:$REPO/"
```

### 2. Build and start

```bash
ssh "$HOST" "cd $REPO && docker compose up -d --build"
```

`open-webui` is recreated because its environment changed; the data volume persists.
Wait for it to report healthy (`docker compose ps`).

### 3. Register the connection on an existing install

On an existing install the startup line still reports the **old** count — the stored
connections winning over the environment variable — and that is expected:

```bash
ssh "$HOST" "docker logs open-webui 2>&1 | grep -E 'Initialized [0-9]+ tool server' | tail -1"
ssh "$HOST" "cd $REPO && ./scripts/sync-tool-servers.sh"
```

The script appends the missing entry, restarts `open-webui`, and prints the new
`Initialized N tool server(s)` line. A fresh volume needs none of this.

### 4. Health check and end to end

```bash
ssh "$HOST" "cd $REPO && ./scripts/health-check.sh"
ssh "$HOST" "cd $REPO && ./scripts/e2e-tool-call.sh --expect <operationId> --question '<question>'"
```

Every section green, and the *resolves the tools* line must name the new
`operationId`. Phrase the question so answering from memory is not an option ("right
now", "this weekend", "today's"). The harness offers **every** registered tool, so it
also tests that the model picks the right one. Re-run it for an existing tool to prove
nothing regressed. The first call loads the model; allow a minute or two.

### 6. Leave the remote tree clean

After verification, restore the remote's tracked files and remove synced untracked
ones so the user's later `git pull` is clean. The running containers keep the tested
build; the checked-out files match again after the pull.

```bash
ssh "$HOST" "cd $REPO && git checkout -- . && git clean -fd -- <new paths>"
```

Tell the user explicitly that until they pull, the remote's compose file describes the
old stack while the containers run the new one, and that `docker compose up` there
before pulling would roll back.

## 5. The chat window (both situations)

The harness does not exercise the UI. Ask the user to open a chat, click the wrench icon
under the message box, switch the new tool on, and ask the question. The tool is listed
but **off** until they do that; see `docs/enable-weather-tool.png`.

If the harness passes but a small model declines in the chat window, the cause is Open
WebUI's builtin tools (35 in 0.11.3) crowding out the one the user selected. Untick
*Builtin Tools* in that model's capabilities (Admin Panel > Models); the README's
troubleshooting section describes it.

## Removing a service

Reverting the files is not enough: the stored connection stays in `webui.db`, so Open
WebUI keeps a dead server in its list. In this order, where the stack runs:

1. `./scripts/sync-tool-servers.sh --remove http://<name>-proxy:<port>` — before
   reverting, since the reverted script may predate the option. Removing an entry
   shifts the positional ids of every entry after it.
2. Revert the files (`git checkout -- .`, `git clean -fd -- <name>-proxy`).
3. `docker compose up -d --remove-orphans`, then
   `docker image rm open-webui-service-weather-<name>-proxy`.
4. `./scripts/health-check.sh` — the resolved-tools line must name only the remaining
   tools.

`docs/adding-a-service.md` shows a complete add-and-remove cycle.
