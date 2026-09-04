# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
import os
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# --------------------------------------------------------------
# Helper: map a user‑friendly location string to lat/lon.
# OpenWeather allows queries by city name, but using lat/lon is
# more reliable for ambiguous city names. We'll use the
# "geo" endpoint to resolve city/state first.
# --------------------------------------------------------------
def resolve_location(city: str, state: str, country: str = "US"):
    geo_url = "http://api.openweathermap.org/geo/1.0/direct"
    params = {
        "q": f"{city},{state},{country}",
        "limit": 1,
        "appid": os.getenv("OWM_API_KEY"),
    }
    r = requests.get(geo_url, params=params, timeout=10)
    data = r.json()
    # print(f"Resolved location data: {data}")
    if not data:
        raise ValueError(f"Could not resolve location {city}, {state}")
    return data[0]["lat"], data[0]["lon"]

# --------------------------------------------------------------
# Main endpoint that OpenWebUI will call.
# Expected payload (JSON):
# {
#   "city": "Princeton",
#   "state": "NJ",
#   "date": "2026-09-07"   # ISO‑8601 (optional – if omitted we give today)
# }
# --------------------------------------------------------------
@app.route("/weather", methods=["POST"])
def weather():
    payload = request.get_json(force=True)

    city = payload.get("city")
    state = payload.get("state")
    date = payload.get("date")          # optional – we’ll just filter later

    if not city or not state:
        return jsonify({"error": "city and state are required"}), 400

    try:
        lat, lon = resolve_location(city, state)
    except Exception as e:
        return jsonify({"error": str(e)}), 400

    # Call the 5‑day / 3‑hour forecast endpoint (returns data in 3‑hour chunks)
    forecast_url = "https://api.openweathermap.org/data/2.5/forecast"
    params = {
        "lat": lat,
        "lon": lon,
        "units": "imperial",           # change to "metric" if you prefer °C
        "appid": os.getenv("OWM_API_KEY"),
    }
    r = requests.get(forecast_url, params=params, timeout=10)
    data = r.json()

    # ----------------------------------------------------------
    # Pick the entries that match the requested date (if given)
    # ----------------------------------------------------------
    result = []
    for entry in data.get("list", []):
        ts = entry["dt_txt"]          # format "2026-09-07 12:00:00"
        if date and not ts.startswith(date):
            continue
        # Simplify to the fields we want to return
        result.append({
            "datetime": ts,
            "temp": entry["main"]["temp"],
            "temp_min": entry["main"]["temp_min"],
            "temp_max": entry["main"]["temp_max"],
            "description": entry["weather"][0]["description"],
            "precip_prob": entry.get("pop", 0) * 100,   # % chance of precipitation
        })

    if not result:
        return jsonify({"error": "No forecast data for the requested date"}), 404

    # Return a compact structure – OpenWebUI will just forward this JSON
    return jsonify({"city": city, "state": state, "forecast": result})

# --------------------------------------------------------------
# OpenAPI 3.1 description of this service.
#
# OpenWebUI registers this process as an "External Tool Server" and
# fetches the document below from <connection-url>/openapi.json. It
# derives the tool name from `operationId` and calls
# <connection-url> + <path key>, i.e. http://weather-proxy:5005/weather.
# The `servers` block is not used for that, so schemas are inlined
# here to keep the document self-contained.
# --------------------------------------------------------------
OPENAPI_SPEC = {
    "openapi": "3.1.0",
    "info": {
        "title": "Weather Proxy",
        "description": (
            "Short-term weather forecasts for US cities. "
            "Weather data provided by OpenWeather (https://openweathermap.org), "
            "licensed under the Open Database License (ODbL)."
        ),
        "version": "1.0.0",
        "license": {"name": "MIT"},
    },
    "servers": [{"url": "http://weather-proxy:5005"}],
    "paths": {
        "/weather": {
            "post": {
                "operationId": "get_weather",
                "summary": "Get a short-term weather forecast for a US city",
                "description": (
                    "Retrieve a short-term weather forecast for a US city "
                    "(city, state, optional date). Returns forecast entries in "
                    "3-hour steps with temperature in Fahrenheit and the "
                    "probability of precipitation in percent. Data is only "
                    "available for roughly the next 5 days; a date outside that "
                    "window returns no data."
                ),
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "properties": {
                                    "city": {
                                        "type": "string",
                                        "description": "Name of the city (e.g., Princeton)",
                                    },
                                    "state": {
                                        "type": "string",
                                        "description": "Two-letter US state abbreviation (e.g., NJ)",
                                    },
                                    "date": {
                                        "type": "string",
                                        "format": "date",
                                        "description": (
                                            "ISO-8601 date to filter the forecast to, e.g. "
                                            "2026-09-07. Must fall within the next 5 days. "
                                            "If omitted, the full available forecast "
                                            "(about 5 days) is returned."
                                        ),
                                    },
                                },
                                "required": ["city", "state"],
                            }
                        }
                    },
                },
                "responses": {
                    "200": {
                        "description": "Forecast for the requested city",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "city": {"type": "string"},
                                        "state": {"type": "string"},
                                        "forecast": {
                                            "type": "array",
                                            "items": {
                                                "type": "object",
                                                "properties": {
                                                    "datetime": {"type": "string"},
                                                    "temp": {"type": "number"},
                                                    "temp_min": {"type": "number"},
                                                    "temp_max": {"type": "number"},
                                                    "description": {"type": "string"},
                                                    "precip_prob": {"type": "number"},
                                                },
                                                "required": ["datetime", "temp", "description"],
                                            },
                                        },
                                    },
                                    "required": ["city", "state", "forecast"],
                                }
                            }
                        },
                    },
                    "400": {"description": "Missing parameters or unresolvable location"},
                    "404": {"description": "No forecast data for the requested date"},
                },
            }
        }
    },
}


@app.route("/openapi.json", methods=["GET"])
def openapi_spec():
    return jsonify(OPENAPI_SPEC)


if __name__ == "__main__":
    # Bind to all interfaces so Docker can reach it
    app.run(host="0.0.0.0", port=5005)
