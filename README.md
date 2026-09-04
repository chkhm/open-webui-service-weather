# open-webui-service-weather

A local [Open WebUI](https://github.com/open-webui/open-webui) instance with a small
weather service attached to it, so the chat model can answer questions like
*"What will the weather be this weekend in Princeton, NJ?"* with real forecast data
instead of declining.

The weather service is a Flask app that wraps [OpenWeather](https://openweathermap.org/).
It describes itself with an OpenAPI document, which Open WebUI registers as an
**external tool server** — that is the mechanism that makes `get_weather` available
to the model.

```
  browser :12000
        |
   +----v----------------+       GET /openapi.json      +------------------+
   |     open-webui      |----------------------------->|                  |
   |  (+ bundled Ollama) |                              |  weather-proxy   |
   |                     |  POST /weather {city,state}  |    (Flask)       |
   |                     |----------------------------->|                  |
   +---------------------+                              +---------+--------+
                                                                  |
                                                                  v
                                                          OpenWeather API
```

## Requirements

- Docker with Compose v2
- An NVIDIA GPU plus the NVIDIA Container Toolkit — `docker-compose.yml` reserves all
  GPUs for the `open-webui` service. Remove that `deploy:` block to run CPU-only.
- An OpenWeather API key (below)

## Getting an OpenWeather API key

1. Create a free account at <https://openweathermap.org/api>.
2. Copy the key from the **API keys** tab of your account page.
3. A new key is not usable immediately — activation commonly takes anywhere from a few
   minutes to a couple of hours. Until then requests come back as unauthorized.

The free tier covers both endpoints this project uses: the Geocoding API
(`geo/1.0/direct`, to turn *Princeton, NJ* into coordinates) and the 5 day / 3 hour
forecast (`data/2.5/forecast`).

## Where to put the key

Copy the example file and fill in your key:

```bash
cp .env.example .env
```

```
OWM_API_KEY=your_key_here
```

`.env` sits in the repository root next to `docker-compose.yml`, which is where Compose
looks for it automatically. It is gitignored — do not commit your key. Nothing else
needs configuring.

## Bringing it up and down

```bash
docker compose up -d          # start (add --build after changing weather-proxy)
docker compose ps             # status
docker compose logs -f        # follow logs
docker compose down           # stop and remove containers, keep all data
```

Open WebUI is then at <http://localhost:12000>, or `http://<host>:12000` if you run it
on another machine. On first start it asks you to create an admin account; that account
lives in the `open-webui` volume.

Ask it something like *"What will the weather be this weekend in Princeton, NJ?"* — the
model should call `get_weather` and answer from the returned forecast.

## Convenience scripts

| Script | What it does |
|---|---|
| `scripts/remove-containers.sh` | Removes the containers and network. Keeps all volumes, so nothing is lost. Equivalent to `docker compose down`, with a summary of what was preserved. |
| `scripts/remove-volumes.sh` | **Destroys data.** Deletes the Open WebUI data volume after a typed confirmation. Pass `--with-models` to also delete the Ollama volume. Refuses to run while containers are up. |

The model volume is excluded by default because it is large — on the development
machine it holds ~61 GB, and everything in it has to be downloaded again.

## How the weather tool is wired up

Two pieces have to line up, and both are in this repository:

1. **The proxy publishes a spec.** `weather-proxy/weather_service.py` serves an OpenAPI
   3.1 document at `GET /openapi.json` describing its `POST /weather` endpoint. The tool
   name the model sees comes from that document's `operationId`.

2. **Compose registers the connection.** `docker-compose.yml` passes
   `TOOL_SERVER_CONNECTIONS` to Open WebUI, pointing at `http://weather-proxy:5005` with
   path `openapi.json`.

Open WebUI resolves those as: spec URL = connection URL + `path`, and the call URL =
connection URL + the path key from the spec. The spec's own `servers` block is ignored.
So the connection must point at the **proxy root**, not at `/weather`.

Environment values are defaults. Once a connection is stored in the database — because
this variable seeded it, or because you edited it in the admin UI — the stored value
wins. The variable therefore sets up a fresh volume without ever overwriting changes you
make later through the interface.

## Volumes

| Volume | Contents | Lost if deleted |
|---|---|---|
| `open-webui` | `webui.db`, uploads, vector store | Admin account, chat history, settings. The tool-server connection is reseeded from `TOOL_SERVER_CONNECTIONS` on next start. |
| `open-webui-ollama` | Downloaded models | Every model, re-downloaded on next pull |

Both are pinned to those exact names in `docker-compose.yml`. Without the pin, Compose
prefixes volume names with the project directory name, and the stack silently comes up
against an empty volume with none of your data in it.

## Troubleshooting

**The model says it cannot look up weather.** The tool server did not load. Check the
spec is reachable from inside the network:

```bash
docker exec open-webui curl -s -o /dev/null -w "%{http_code}\n" http://weather-proxy:5005/openapi.json
```

`200` is expected. A `404` usually means the stored connection points at
`http://weather-proxy:5005/weather` instead of the root, which resolves the spec to
`/weather/openapi.json`. Fix it in the admin UI's external tool server settings.

**Forecasts fail for dates more than five days out.** That is the limit of the
OpenWeather endpoint in use; the proxy returns 404 and the spec tells the model about
the limit.

**Everything returns unauthorized.** Either `OWM_API_KEY` is empty in `.env`, or the key
has not activated yet. Check what the container actually received:

```bash
docker exec weather-proxy printenv OWM_API_KEY
```

**A note on `custom_functions.json`.** Earlier versions of this project carried such a
file, on the assumption that Open WebUI reads function definitions from the data volume.
It does not — the only file it imports from that directory is `config.json`. The file
was inert and has been removed; tools are registered through the mechanism described
above.
