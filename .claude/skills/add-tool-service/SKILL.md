---
name: add-tool-service
description: This skill should be used when the user asks to "add a tool service", "add a new tool to Open WebUI", "scaffold a proxy for an API", "make <some API> available to the model", or invokes /add-tool-service. It adds a new HTTP service to this repository's Open WebUI docker-compose setup so that the model can call it as a tool, following the same conventions as weather-proxy.
argument-hint: <service-name> [one-line purpose]
allowed-tools: Read Write Edit Bash AskUserQuestion WebFetch
version: 1.0.0
---

# Add a tool service

Add a new tool service to this repository: a small Flask proxy that wraps an upstream
API and publishes an OpenAPI document, wired into `docker-compose.yml`, registered with
Open WebUI, covered by `scripts/health-check.sh`, and documented in `README.md`.

`weather-proxy/weather_service.py` is the reference implementation. Every convention
below exists because getting it wrong failed *silently*: the model simply says it cannot
do the thing, and nothing appears in any log. Read `references/pitfalls.md` before
writing anything and apply it before deploying.

The service name comes from `$ARGUMENTS` (first word, e.g. `currency`). The directory,
container and network alias are all `<name>-proxy`.

## Workflow

### 1. Intake

Ask everything in one `AskUserQuestion` round, then confirm the summary before writing:

- **Purpose** in one sentence, and the question a user would ask in chat.
- **Upstream API**: base URL, method, an example request and response. For a keyless
  API offer to probe it directly.
- **Operations**: one `operationId` per endpoint in `snake_case` (this *is* the tool name
  the model sees), with parameters: name, type, required, example, description.
- **Secret**: does the upstream need a key? If so: environment variable name, where to
  obtain it, any activation delay. If not, say so explicitly.
- **Practical limits** the model must know to call it well: date ranges, coverage,
  update cadence, units, supported codes.
- **Data licence and attribution** required by the upstream.
- **Port**: default is the highest `500x` in `docker-compose.yml` plus one.
- **Deploy target** (default `spark01`, path `~/git/open-webui-service-weather`) and
  whether to deploy and verify now.

### 2. Preflight

- Require a clean `git status` for tracked files.
- Read `docker-compose.yml`, `scripts/health-check.sh`, `README.md`, and
  `weather-proxy/weather_service.py`.
- For a keyless upstream, `curl` the happy path and two error cases (bad parameter,
  unknown code) and record the exact response shapes; they drive the error mapping.
- Check the proposal for collisions before writing anything:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/add_tool_service.py" validate \
    --name <name> --port <port> --operation-id <operationId>
```

### 3. Generate

Work in this order; each step's output is reviewable as an ordinary diff.

1. **Service code.** Copy `assets/service.py.tmpl` to `<name>-proxy/<name>_service.py`
   and `assets/Dockerfile.tmpl` to `<name>-proxy/Dockerfile`. Replace every `__TOKEN__`.
   Implement the upstream call in the marked region. Write the OpenAPI document per
   `references/openapi-guidelines.md`: inline schemas, `operationId` per operation,
   practical limits in the *operation* description, attribution in `info.description`.
2. **Wiring.** Run the helper, which appends the compose service, the connection entry,
   the `depends_on` line, the health-check container, and (with `--secret`) the
   `.env.example` variable. It re-parses its own output and refuses to leave the
   connections JSON invalid:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/add_tool_service.py" add \
    --name <name> --port <port> --operation-id <operationId> \
    --info-description "<short phrase for the admin UI>" \
    [--secret <VAR> --secret-comment "<where to get it>"] [--dry-run]
```

3. **Health check.** Copy the function from `assets/health-check-section.sh.tmpl` into
   `scripts/health-check.sh` after `check_weather_proxy`, fill in the live call, call it
   in the main flow after the weather call, and add the `operationId` to the
   `check_resolved` line.
4. **README.** Use `assets/readme-snippets.md`: a node and edges in the architecture diagram, one
   sentence in the intro, the wiring section generalised to cover all services, a
   `### <Source> data` attribution block under *License and attribution*, a
   troubleshooting `curl` line, and, only if there is a secret, the key sections.
5. **Headers.** Every new file carries the SPDX and copyright header used throughout.

### 4. Apply the pitfalls checklist

Go through `references/pitfalls.md` item by item and report the result to the user
before deploying. Fix anything that fails; do not proceed with a known miss.

### 5. Validate locally

```bash
docker compose config --quiet
bash -n scripts/health-check.sh
python3 -m py_compile <name>-proxy/<name>_service.py
python3 "${CLAUDE_SKILL_DIR}/scripts/add_tool_service.py" validate
```

Confirm the rendered connections still parse and now have one more entry:

```bash
docker compose config --format json | python3 -c 'import sys,json; c=json.load(sys.stdin); v=json.loads(c["services"]["open-webui"]["environment"]["TOOL_SERVER_CONNECTIONS"]); print(len(v), [x["url"] for x in v])'
```

### 6. Deploy and verify

Follow `references/deploy-and-verify.md`. In short: sync the repository to the target,
`docker compose up -d --build`, run `./scripts/sync-tool-servers.sh` (the stored
connections win over the environment variable on an existing install), then
`./scripts/health-check.sh`, then `./scripts/e2e-tool-call.sh --expect <operationId>`
with a question that demands live data. Finally ask the user to switch the tool on under
the wrench icon in a chat and try it there; registration does not enable it.

### 7. Report

List the files created and changed, the health-check and end-to-end results, and the
two standing caveats: existing installs need `sync-tool-servers.sh` (or the admin UI),
and the tool must be toggled on per chat. Offer to commit; never commit unasked.

## Rules that are easy to get wrong

- The connection `url` is the service **root**, `http://<name>-proxy:<port>`, never an
  endpoint. Open WebUI appends `path` for the spec and the operation's path for calls.
- `operationId` must be unique across every service. Open WebUI silently renames a
  duplicate to `<index>_<name>` rather than failing.
- Never reorder or edit existing connection entries. Tool ids are positional.
- The environment variable seeds an empty database only. On an existing install the new
  connection must be written to the database (`sync-tool-servers.sh`).
- Keep licence and attribution text out of the operation description; it is what the
  model reads to decide whether and how to call the tool.

## Additional resources

### Reference files

- **`references/wiring.md`** — how Open WebUI resolves tool servers, with the source
  locations the rules were read from; the anatomy of a connection entry.
- **`references/openapi-guidelines.md`** — what goes where in the OpenAPI document,
  request/response conventions, error mapping.
- **`references/pitfalls.md`** — the checklist applied in step 4.
- **`references/deploy-and-verify.md`** — the deployment and verification sequence.

### Assets

- **`assets/service.py.tmpl`**, **`assets/Dockerfile.tmpl`** — service skeleton.
- **`assets/health-check-section.sh.tmpl`** — the per-service check function.
- **`assets/readme-snippets.md`** — README fragments to adapt.

### Scripts

- **`scripts/add_tool_service.py`** — deterministic edits to `docker-compose.yml`,
  `scripts/health-check.sh` and `.env.example`, plus collision validation. Standard
  library only.
