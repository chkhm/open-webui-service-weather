# OpenAPI document guidelines

The proxy serves one OpenAPI 3.1 document at `GET /openapi.json`. It is the only thing
Open WebUI reads about the service, and it doubles as the model's instructions for using
the tool. `weather-proxy/weather_service.py` (`OPENAPI_SPEC`) is the worked example.

## Structure

```python
OPENAPI_SPEC = {
    "openapi": "3.1.0",
    "info": {
        "title": "...",                 # shown in the admin UI
        "description": "...",           # attribution and licence of the DATA (see below)
        "version": "1.0.0",
        "license": {"name": "MIT"},     # licence of THIS service
    },
    "servers": [{"url": "http://<name>-proxy:<port>"}],   # informational only; ignored by Open WebUI
    "paths": {
        "/<endpoint>": {
            "post": {
                "operationId": "<tool_name>",
                "summary": "...",
                "description": "...",   # what the MODEL reads (see below)
                "requestBody": {"required": True, "content": {"application/json": {"schema": {...}}}},
                "responses": {"200": {...}, "400": {...}, "404": {...}},
            }
        }
    },
}
```

Keep everything inline. Do not use `components` or `$ref`; a self-contained document has
nothing to resolve and nothing to get wrong.

## The two descriptions

**Operation `description`** — the model reads this to decide whether to call the tool
and how. Write for the model:

- what the tool does, in one sentence
- what the parameters mean and their format, with an example value
- **practical limits**: date windows, coverage, update cadence, units, supported codes.
  Without them the model asks for things the upstream cannot answer and gets an error
  it cannot interpret. Weather learned this the hard way: without "data is only
  available for the next 5 days" the model asked for a date a week out and got a 404.
- no licence text, no attribution, no implementation detail

**`info.description`** — the place for data attribution and licence, e.g.
*"Weather data provided by OpenWeather (https://openweathermap.org), licensed under the
Open Database License (ODbL)."* Not read by the model.

## Request convention

- `POST` with a JSON body. Open WebUI sends every model argument as the body, so the
  request schema is exactly the tool's parameter list.
- Every property carries a `description` and, where useful, `format` (`date`) or an
  `enum`. The model relies on these.
- `required` lists only what the upstream truly needs.
- Coerce on the server: models pass numbers as strings and codes in lower case. Accept
  and normalise rather than reject.

## Response convention

- Return a compact JSON object with the fields the model needs to answer, named plainly.
  Reshape the upstream response; do not forward it raw.
- Include a `source` or `date` field when the data's provenance or freshness matters to
  the answer (e.g. an exchange rate's reference date).
- Document the 200 shape in `responses` with an inline schema. It is not used by Open
  WebUI but it is the contract.

## Error convention

- Missing or invalid parameter → `400 {"error": "..."}` that says what to fix.
- Upstream says "not found" (unknown city, unknown currency) → `400` or `404` with a
  hint that helps the model recover (e.g. list where valid codes come from).
- Upstream unreachable or timed out → `502 {"error": "..."}`.
- Always `timeout=10` on upstream calls and catch `requests.RequestException`.

Open WebUI wraps any 4xx/5xx as `{"error": "HTTP error <status>: <body>"}` for the
model, so the body text is what the model sees. Make it a sentence, not a stack trace.

## Naming

- `operationId` in `snake_case`, a verb phrase: `get_weather`, `convert_currency`.
  It must be unique across all services in the repository.
- Endpoint path short and singular: `/weather`, `/convert`.
- Port: one number, used identically in `app.run`, `EXPOSE`, compose `expose`, the
  connection `url`, the `servers` block, and the health check.
