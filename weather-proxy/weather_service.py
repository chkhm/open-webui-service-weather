# weather_service.py
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

if __name__ == "__main__":
    # Bind to all interfaces so Docker can reach it
    app.run(host="0.0.0.0", port=5005)
