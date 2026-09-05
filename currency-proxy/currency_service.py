# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
#
# currency-proxy: makes Frankfurter available to Open WebUI as the tool
# `convert_currency`. Serves an OpenAPI document at /openapi.json that Open WebUI
# registers as an external tool server; see README.md, "How the tools are wired up".
import datetime
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

UPSTREAM = "https://api.frankfurter.dev/v1"
PORT = 5006
SOURCE = "European Central Bank reference rates via Frankfurter"


def _error(status, message):
    return jsonify({"error": message}), status


# --------------------------------------------------------------
# Tool endpoint. Open WebUI sends every argument the model produced as
# the JSON body, so the body is exactly the parameter list in the
# OpenAPI document below. Coerce and normalise here: models pass numbers
# as strings and codes in lower case.
# --------------------------------------------------------------
@app.route("/convert", methods=["POST"])
def convert_currency():
    payload = request.get_json(force=True, silent=True) or {}

    # --- parameters ------------------------------------------------
    try:
        amount = float(payload.get("amount"))
    except (TypeError, ValueError):
        return _error(400, "amount must be a number, e.g. 100")
    if amount <= 0:
        return _error(400, "amount must be greater than zero")

    src = str(payload.get("from_currency") or "").strip().upper()
    dst = str(payload.get("to_currency") or "").strip().upper()
    for code in (src, dst):
        if len(code) != 3 or not code.isalpha():
            return _error(400, "from_currency and to_currency must be three-letter "
                               "ISO 4217 codes, e.g. USD and EUR")

    if src == dst:
        # Frankfurter rejects an identical pair (422); the answer is trivial.
        return jsonify({
            "amount": amount,
            "from_currency": src,
            "to_currency": dst,
            "converted_amount": round(amount, 2),
            "rate": 1.0,
            "date": datetime.date.today().isoformat(),
            "source": SOURCE,
        })

    # --- upstream call ---------------------------------------------
    try:
        r = requests.get(
            f"{UPSTREAM}/latest",
            params={"amount": amount, "from": src, "to": dst},
            timeout=10,
        )
    except requests.RequestException as e:
        return _error(502, f"Frankfurter is unreachable: {e}")

    if r.status_code == 404:
        return _error(400, f"unknown currency code in {src} -> {dst}; Frankfurter covers "
                           "about 30 major currencies by ISO 4217 code, e.g. USD, EUR, "
                           "GBP, JPY, CHF, CAD, AUD, CNY")
    if r.status_code == 422:
        return _error(400, f"Frankfurter cannot convert {src} to {dst}")
    if r.status_code >= 400:
        return _error(502, f"Frankfurter returned {r.status_code}")

    data = r.json()
    converted = data.get("rates", {}).get(dst)
    if converted is None:
        return _error(502, "Frankfurter response did not include the requested rate")
    converted = float(converted)

    # --- response ----------------------------------------------------
    return jsonify({
        "amount": amount,
        "from_currency": src,
        "to_currency": dst,
        "converted_amount": round(converted, 2),
        "rate": round(converted / amount, 6),
        "date": data.get("date"),
        "source": SOURCE,
    })


# --------------------------------------------------------------
# OpenAPI 3.1 document. Open WebUI fetches <connection url>/openapi.json,
# names the tool after `operationId`, and calls <connection url> + the
# path key ("/convert"). The `servers` block is informational only.
#
# Two descriptions, two audiences:
#   - the OPERATION description is what the model reads to decide whether
#     and how to call the tool: purpose, parameter hints, practical limits.
#     No licence text.
#   - info.description carries the data attribution the upstream requires.
# --------------------------------------------------------------
OPENAPI_SPEC = {
    "openapi": "3.1.0",
    "info": {
        "title": "Currency Proxy",
        "description": (
            "Currency conversion at daily reference rates. Exchange rate data from "
            "the European Central Bank, served by Frankfurter (https://frankfurter.dev), "
            "which requires no API key."
        ),
        "version": "1.0.0",
        "license": {"name": "MIT"},
    },
    "servers": [{"url": f"http://currency-proxy:{PORT}"}],
    "paths": {
        "/convert": {
            "post": {
                "operationId": "convert_currency",
                "summary": "Convert an amount between two currencies",
                "description": (
                    "Convert an amount from one currency to another using the daily "
                    "European Central Bank reference rates, served by Frankfurter. "
                    "These are official daily reference rates published on working "
                    "days around 16:00 CET, not live market rates; on weekends and "
                    "holidays the most recent working day's rate is used, and the "
                    "response's date field says which day it is from. About 30 major "
                    "currencies are supported by ISO 4217 code (USD, EUR, GBP, JPY, "
                    "CHF, CAD, AUD, CNY, ...); other codes return an error."
                ),
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "properties": {
                                    "amount": {
                                        "type": "number",
                                        "description": "Amount to convert, e.g. 100",
                                    },
                                    "from_currency": {
                                        "type": "string",
                                        "description": "ISO 4217 code of the currency to convert from, e.g. USD",
                                    },
                                    "to_currency": {
                                        "type": "string",
                                        "description": "ISO 4217 code of the currency to convert to, e.g. EUR",
                                    },
                                },
                                "required": ["amount", "from_currency", "to_currency"],
                            }
                        }
                    },
                },
                "responses": {
                    "200": {
                        "description": "The converted amount and the rate used",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "amount": {"type": "number"},
                                        "from_currency": {"type": "string"},
                                        "to_currency": {"type": "string"},
                                        "converted_amount": {"type": "number"},
                                        "rate": {"type": "number"},
                                        "date": {
                                            "type": "string",
                                            "description": "Reference date of the rate used (ISO 8601)",
                                        },
                                        "source": {"type": "string"},
                                    },
                                    "required": ["amount", "from_currency", "to_currency",
                                                 "converted_amount", "rate", "date"],
                                }
                            }
                        },
                    },
                    "400": {"description": "Missing or invalid parameter, or unknown currency code"},
                    "502": {"description": "Frankfurter unavailable"},
                },
            }
        }
    },
}


@app.route("/openapi.json", methods=["GET"])
def openapi_spec():
    return jsonify(OPENAPI_SPEC)


if __name__ == "__main__":
    # Bind to all interfaces so the other containers can reach it
    app.run(host="0.0.0.0", port=PORT)
