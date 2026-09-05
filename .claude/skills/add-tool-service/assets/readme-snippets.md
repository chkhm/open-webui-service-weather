# README fragments

Adapt these; do not paste them verbatim. Match the surrounding prose.

## Intro sentence (after the paragraph describing the weather service)

> A second service, `<name>-proxy`, does the same for <upstream> so the model can
> <what the user gets>, e.g. *"<example question>"*.

## Architecture diagram

Add a box to the right of `weather-proxy`, fed by the same two arrows from `open-webui`,
and an arrow down to the upstream. Keep the box width consistent. Example with two
services:

```
  browser :12000
        |
   +----v----------------+   GET /openapi.json    +------------------+   +------------------+
   |     open-webui      |----------------------->|  weather-proxy   |   |  currency-proxy  |
   |                     |   POST /weather        |    (Flask)       |   |    (Flask)       |
   |                     |----------------------->|                  |   |                  |
   |                     |   GET /openapi.json    +---------+--------+   +---------+--------+
   |                     |-------------------------------------------------->|
   |                     |   POST /convert                                   |
   |                     |-------------------------------------------------->|
   +----------+----------+                                 |                 |
              |                                            v                 v
              | OLLAMA_BASE_URL                    OpenWeather API      Frankfurter API
              | http://ollama:11434
   +----------v----------+
   |       ollama        |  <- holds the GPU and the model store
   +---------------------+
```

## Wiring section

Retitle "How the weather tool is wired up" to "How the tools are wired up" and make the
two numbered points cover every service: each `*-proxy` publishes its own
`/openapi.json`, and `TOOL_SERVER_CONNECTIONS` holds one entry per service. Add a short
table of services: name, port, tool name, upstream.

## Attribution block (under "## License and attribution", after "### Weather data")

```markdown
### <Source> data

**<Data> provided by [<Upstream>](<url>).**

<One or two sentences: what licence the data is under, whether a key is needed, and
what attribution the upstream asks for. The proxy states this in the `info` block of
its OpenAPI document.>
```

## Troubleshooting

Add the service's spec check next to weather's:

```bash
docker exec open-webui curl -s -o /dev/null -w "%{http_code}\n" http://<name>-proxy:<port>/openapi.json
```

If the upstream has a characteristic failure (a key that activates slowly, a data
window, a rate limit), add a bolded-symptom paragraph for it in the existing style.

## Key sections (only when there is a secret)

- "Getting an OpenWeather API key" → add a sibling section for the new upstream.
- "Where to put the key" → list the new variable alongside `OWM_API_KEY`.
- `.env.example` already has the variable (added by the helper script); mention it.
