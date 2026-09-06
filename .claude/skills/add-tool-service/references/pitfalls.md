# Pitfalls checklist

Apply every item before deploying and report the outcome. Each one corresponds to a
failure that produced no error anywhere: the model just said it could not help.

## Connection

- [ ] `url` is the service root `http://<name>-proxy:<port>` — no endpoint, no trailing
      slash. Open WebUI appends `path` for the spec and the operation path for calls.
- [ ] `path` is `openapi.json`.
- [ ] The entry was **appended**; existing entries are byte-for-byte unchanged and in
      the same order. Tool ids are positional (`server:<index>`).
- [ ] `info.id` is empty (index fallback), `info.name` is the `operationId`.
- [ ] The rendered value parses: `docker compose config --format json` → the
      `TOOL_SERVER_CONNECTIONS` string `json.loads` to a list with one more entry than
      before. A broken value makes Open WebUI log one error line and seed `[]`.
- [ ] The YAML folded scalar has no blank lines and every continuation line is indented
      deeper than the `- >-` line.

## OpenAPI document

- [ ] `operationId` is `snake_case` and unique across every `*-proxy/*_service.py`.
      Duplicates are silently renamed `<index>_<name>`.
- [ ] Operation `description` states purpose, parameter hints, and practical limits;
      contains no licence or attribution text.
- [ ] `info.description` carries the data attribution the upstream requires.
- [ ] Schemas are inline; no `components`, no `$ref`.
- [ ] Operation is `post` with a `requestBody`; every property has a `description`.
- [ ] Server-side coercion: numeric strings to numbers, codes upper-cased.
- [ ] Errors are JSON with an `error` key and a 4xx/5xx status; upstream calls have a
      timeout and catch `requests.RequestException`.

## Compose and files

- [ ] Directory, `container_name`, network alias and `build` path are all `<name>-proxy`.
- [ ] One port, identical in `app.run`, `EXPOSE`, compose `expose`, the connection
      `url`, the `servers` block and the health check. Not used by any other service.
- [ ] `restart: unless-stopped`.
- [ ] A secret, if any, is `${VAR}` from `.env`, listed in `.env.example` with a comment
      saying where to get it, and never written into a tracked file.
- [ ] `open-webui.depends_on` includes the new service.
- [ ] SPDX and copyright header at the top of every new file.
- [ ] Nothing under `weather-proxy/` changed.

## Health check

- [ ] The container is in `CONTAINERS`.
- [ ] `check_<name>_proxy` covers: credentials (if any), spec via `check_spec`,
      connection via `check_connection` with the root url, and one live call that
      asserts a specific field of a specific known-good request.
- [ ] The function is called in the main flow and the `operationId` is in the
      `check_resolved` call.
- [ ] `bash -n scripts/health-check.sh` passes.

## README

- [ ] Architecture diagram has a node, edges and a class assignment for the service.
- [ ] Wiring section covers the service; troubleshooting has its `curl` line.
- [ ] `### <Source> data` attribution block under *License and attribution*.
- [ ] Key sections updated only if there is a secret.

## After deploying

- [ ] On an existing install: `sync-tool-servers.sh` ran, and the log line moved from
      `Initialized N` to `Initialized N+1 tool server(s)`.
- [ ] `health-check.sh` all green, including the resolved-tools line naming the new tool.
- [ ] `e2e-tool-call.sh --expect <operationId>` shows the model choosing the new tool
      when all tools are on offer, and the old tools still work.
- [ ] The user has been told the tool must be switched on per chat under the wrench.
