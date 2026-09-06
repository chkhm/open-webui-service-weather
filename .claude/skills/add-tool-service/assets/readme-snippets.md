# README fragments

Adapt these; do not paste them verbatim. Match the surrounding prose.

## Intro sentence (after the paragraph describing the weather service)

> A second service, `<name>-proxy`, does the same for <upstream> so the model can
> <what the user gets>, e.g. *"<example question>"*.

## Architecture diagram

The README diagram is Mermaid, coloured by role via `classDef` (`ui`, `model`, `proxy`,
`upstream`). A new service needs four lines and touches nothing else:

1. a node inside the `stack` subgraph: `<name>[<name>-proxy :<port>]`
2. an upstream node outside it: `<id>[<Upstream> API]`
3. the edge chain: `owui -- "GET /openapi.json, POST /<endpoint>" --> <name> --> <id>`
4. the ids appended to the `class ... proxy` and `class ... upstream` lines

Keep labels on one line (no HTML breaks; their rendering is not guaranteed on GitHub).
Example with three services — the lines marked `+` are the additions for `countries`:

```mermaid
flowchart LR
    browser([browser :12000])

    subgraph stack [docker compose stack]
        direction LR
        owui[open-webui]
        ollama[(ollama - GPU and model store)]
        weather[weather-proxy :5005]
        currency[currency-proxy :5006]
        countries[countries-proxy :5007]                                     %% +
    end

    owm[OpenWeather API]
    frank[Frankfurter API]
    rc[REST Countries API]                                                   %% +

    browser --> owui
    owui -- OLLAMA_BASE_URL --> ollama
    owui -- "GET /openapi.json, POST /weather" --> weather --> owm
    owui -- "GET /openapi.json, POST /convert" --> currency --> frank
    owui -- "GET /openapi.json, POST /country" --> countries --> rc          %% +

    classDef ui fill:#dbeafe,stroke:#1d4ed8,color:#111
    classDef model fill:#ede9fe,stroke:#6d28d9,color:#111
    classDef proxy fill:#dcfce7,stroke:#15803d,color:#111
    classDef upstream fill:#fef3c7,stroke:#b45309,color:#111
    class owui ui
    class ollama model
    class weather,currency,countries proxy                                   %% +
    class owm,frank,rc upstream                                              %% +
```

Leave the caption line under the diagram as it is; the colours are per role, so it does
not change.

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
