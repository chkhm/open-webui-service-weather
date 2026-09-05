# How Open WebUI wires an external tool server

These rules were read from the Open WebUI source inside the pinned image (v0.11.3,
`/app/backend/open_webui/`) and confirmed by probing the running instance. They are not
documented upstream. If the image is upgraded, re-verify them against the same files.

## Registration

`config.py` (around line 380) parses the environment variable:

```python
tool_server_connections = JSONCodec.loads(os.getenv('TOOL_SERVER_CONNECTIONS', '[]'))
```

and maps it to the persistent config key `tool_server.connections`. Environment values
are **defaults**; when persistent config is enabled (the default) the value stored in
`webui.db` (`config` table, key `tool_server.connections`, JSON text) overlays them.

Consequences:

- A fresh volume is seeded from the variable. `docker compose logs open-webui` shows
  `Initialized N tool server(s)` at startup.
- Once stored, the database wins. Changing the variable later does nothing on that
  install. `scripts/sync-tool-servers.sh` appends missing entries to the stored list and
  restarts `open-webui`; the admin UI (Admin Panel > Settings > External Tools) is the
  manual alternative. The admin UI's save replaces the whole array.
- The variable is a supported feature that is missing from the environment variable
  reference (open-webui#15574).

## Connection entry anatomy

```json
{"url": "http://weather-proxy:5005", "path": "openapi.json", "type": "openapi",
 "auth_type": "bearer", "headers": null, "key": "", "spec_type": "url", "spec": "",
 "config": {"enable": true, "function_name_filter_list": "", "access_grants": []},
 "info": {"id": "", "name": "get_weather", "description": "Retrieve short term weather forecast"}}
```

- `url` — the service root. See resolution below.
- `path` — appended to `url` to fetch the OpenAPI document.
- `auth_type: bearer` with an empty `key` sends an empty bearer header; harmless.
- `config.access_grants: []` — empty means admin-only (`utils/access_control/__init__.py`,
  `has_connection_access`). Add grants in the admin UI to expose the tool to other users.
- `info.id` — empty. `get_tool_servers_data` (`utils/tools.py`, around line 1539) falls
  back to `str(idx)`, the array index, so the tool server's id is positional: weather is
  `server:0`, the next service is `server:1`. **Never reorder entries.**
- `info.name` / `info.description` — shown in the admin UI only.

## URL resolution

`utils/tools.py`:

- `get_tool_server_url(url, path)` (around line 1777): spec URL is `url.rstrip('/')`
  plus `/` plus `path`.
- `execute_tool_server` (around line 1622): call URL is `url.rstrip('/')` plus the
  **path key from the OpenAPI document** (`/weather`), with path parameters substituted
  and query parameters appended.
- The OpenAPI document's `servers` block is **ignored**.

So `url` must be the root. A connection at `http://weather-proxy:5005/weather` resolves
the spec to `/weather/openapi.json` (404) and the tool never loads.

## What the model sees

`convert_openapi_to_tool_payload` (around line 1071) turns each operation into a tool:

- name = `operationId`
- description = the operation's `description` (falling back to `summary`)
- parameters = the request body schema (for `requestBody`) merged with declared
  `parameters`; `$ref`s are resolved via `components`, but inlining avoids the question.

`get_tools` builds the dict the model is offered from. If two servers declare the same
`operationId`, the second is renamed `<server_id>_<operationId>` silently. Uniqueness is
the skill's job.

## How a call is executed

For `post`/`put`/`patch`/`delete` operations with a `requestBody`, **all** of the model's
arguments are sent as the JSON body. For `get`, only parameters declared `in: query` are
forwarded. Use POST with a JSON body, like weather.

Any upstream status of 400 or more becomes `{"error": "HTTP error <status>: <body>"}`
handed back to the model, so a 4xx JSON body from the proxy is still readable. Return
errors as JSON with an `error` key and a 4xx status.

## What the chat window does

Tool servers reach a completion only when the UI includes them (`utils/middleware.py`,
`metadata['tool_servers']` / `tool_ids`). The user enables a tool per conversation under
the wrench icon by the message box, or attaches it to a model under Workspace > Models.
A correctly registered tool that is not toggled on produces the classic symptom: the
model says it cannot look the thing up. `routers/tools.py` (around line 105) lists tool
servers as `server:<id>` in the tool picker.
