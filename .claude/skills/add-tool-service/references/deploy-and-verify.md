# Deploy and verify

The deployment target is a separate machine (default `spark01`, repository at
`~/git/open-webui-service-weather`). The project convention is: edit here, sync there,
verify, then commit here on a topic branch and let the user merge, push and pull. Do
not commit on the target, and leave its working tree in a state that `git pull` will
accept.

## 1. Sync the working tree

Copy only what changed. Never copy `.git` or `.env`; the target's `.env` holds the real
secrets and is the only copy.

```bash
rsync -av --exclude .git --exclude .env --exclude '__pycache__' \
    ./ spark01:~/git/open-webui-service-weather/
```

`scp` of individual files is fine for small changes.

## 2. Build and start

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && docker compose up -d --build'
```

`open-webui` is recreated because its environment changed; the data volume persists.
Wait for it to report healthy (`docker compose ps`).

Check the startup line. On an existing install it still reports the **old** count —
that is the stored connections winning over the environment variable, and it is
expected:

```bash
ssh spark01 'docker logs open-webui 2>&1 | grep -E "Initialized [0-9]+ tool server" | tail -1'
```

## 3. Register the connection on an existing install

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && ./scripts/sync-tool-servers.sh'
```

It appends the missing entry, restarts `open-webui`, and prints the new
`Initialized N tool server(s)` line. A fresh volume needs none of this.

## 4. Health check

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && ./scripts/health-check.sh'
```

Every section green, and the final *resolves the tools* line must name the new
`operationId`. Fix and repeat before going further.

## 5. End to end with the model

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && ./scripts/e2e-tool-call.sh \
    --expect <operationId> --question "<a question that demands live data>"'
```

Phrase the question so that answering from memory is not an option ("right now",
"this weekend", "today's"). The harness offers **every** registered tool, so this also
tests that the model picks the right one. Then re-run it for an existing tool to prove
nothing regressed:

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && ./scripts/e2e-tool-call.sh \
    --expect get_weather --question "What will the weather be this weekend in Princeton, NJ?"'
```

This takes a minute or two: the first call loads the model.

## 6. The chat window

The harness does not exercise the UI. Ask the user to open a chat, click the wrench
icon under the message box, switch the new tool on, and ask the question. The tool is
listed but **off** until they do that; see `docs/enable-weather-tool.png`.

## 7. Leave the target clean

After verification, restore the target's tracked files and remove synced untracked
ones so the user's later `git pull` is clean. The running containers keep the tested
build; the checked-out files will match again after the pull.

```bash
ssh spark01 'cd ~/git/open-webui-service-weather && git checkout -- . && git clean -fd -- <new paths>'
```

Tell the user explicitly that until they pull, the target's compose file describes the
old stack while the containers run the new one, and that `docker compose up` there
before pulling would roll back.
