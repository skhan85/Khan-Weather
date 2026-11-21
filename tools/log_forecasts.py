#!/usr/bin/env python3
"""Append one snapshot of hourly forecasts for Milton to a JSON-lines log.

Run every few hours by .github/workflows/forecast-log.yml. Each line holds the time the
forecast was fetched and, per source, the next 120 hours of temperature (°C), precipitation
(mm/h) and precipitation probability (%). tools/score_forecast_log.py later scores the
snapshots against Environment Canada observations by lead time.

Sources: Open-Meteo (each model the app blends, so the blend can be rebuilt offline), Pirate
Weather (PIRATE_WEATHER_KEY) and Google's Weather API (GOOGLE_WEATHER_KEY; 5 calls a run, about
3,600 a month, inside Google's 10,000 free calls). A source whose key is missing or whose request
fails is recorded with its error and skipped.
"""
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

LAT, LON = 43.513, -79.882
HOURS = 120
OPEN_METEO_MODELS = ["gem_seamless", "gem_hrdps_continental", "gfs_seamless", "gfs_hrrr",
                     "ecmwf_ifs025", "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless"]


def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-forecast-log", **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def hour_key(ts):
    """Unix seconds, rounded down to the hour."""
    return int(ts) // 3600 * 3600


def open_meteo():
    q = urllib.parse.urlencode({
        "latitude": LAT, "longitude": LON, "timeformat": "unixtime", "forecast_hours": HOURS,
        "hourly": "temperature_2m,precipitation,precipitation_probability",
        "models": ",".join(OPEN_METEO_MODELS)})
    h = get("https://api.open-meteo.com/v1/forecast?" + q)["hourly"]
    out = {}
    for m in OPEN_METEO_MODELS:
        temps = h.get(f"temperature_2m_{m}")
        if not temps:
            continue
        precip = h.get(f"precipitation_{m}") or [None] * len(temps)
        prob = h.get(f"precipitation_probability_{m}") or [None] * len(temps)
        out["om:" + m] = [[hour_key(t), a, b, c] for t, a, b, c in zip(h["time"], temps, precip, prob)
                          if a is not None]
    return out


def pirate_weather(key):
    url = (f"https://api.pirateweather.net/forecast/{key}/{LAT},{LON}"
           "?units=si&extend=hourly&exclude=currently,minutely,daily,alerts")
    rows = get(url)["hourly"]["data"][:HOURS]
    return {"pirate": [[hour_key(r["time"]), r.get("temperature"), r.get("precipIntensity"),
                        None if r.get("precipProbability") is None else round(100 * r["precipProbability"])]
                       for r in rows]}


def google(key):
    rows, token = [], None
    while len(rows) < HOURS:
        q = {"key": key.strip(), "location.latitude": LAT, "location.longitude": LON, "hours": HOURS, "pageSize": 24}
        if token:
            q["pageToken"] = token
        d = get("https://weather.googleapis.com/v1/forecast/hours:lookup?" + urllib.parse.urlencode(q))
        for h in d.get("forecastHours", []):
            start = dt.datetime.fromisoformat(h["interval"]["startTime"].replace("Z", "+00:00"))
            p = h.get("precipitation") or {}
            rows.append([hour_key(start.timestamp()), (h.get("temperature") or {}).get("degrees"),
                         (p.get("qpf") or {}).get("quantity"), (p.get("probability") or {}).get("percent")])
        token = d.get("nextPageToken")
        if not token:
            break
    return {"google": rows[:HOURS]}


def netatmo():
    """Every Netatmo station within 8 km of Milton as [km, °C, minutes old], nearest first, so
    their bias against Environment Canada and the models can be measured later."""
    import math
    relay = os.environ.get("RELAY_URL", "https://weather-relay.khanofmilton.ca")
    d = get(f"{relay}/v1/netatmo?lat={LAT}&lon={LON}")
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    rows = []
    for s in d.get("stations", []):
        if s.get("temperature") is None or s.get("observed") is None:
            continue
        p = math.pi / 180
        a = (math.sin((s["lat"] - LAT) * p / 2) ** 2
             + math.cos(LAT * p) * math.cos(s["lat"] * p) * math.sin((s["lon"] - LON) * p / 2) ** 2)
        km = 2 * 6371 * math.asin(math.sqrt(a))
        if km <= 8:
            rows.append([round(km, 2), s["temperature"], round((now - s["observed"]) / 60)])
    return {"netatmo": sorted(rows)}


def main(path):
    snap = {"fetched": int(dt.datetime.now(dt.timezone.utc).timestamp()), "sources": {}, "errors": {}}
    jobs = [("open-meteo", open_meteo, None),
            ("pirate", pirate_weather, os.environ.get("PIRATE_WEATHER_KEY")),
            ("google", google, os.environ.get("GOOGLE_WEATHER_KEY")),
            ("netatmo", netatmo, None)]
    for name, fn, key in jobs:
        if fn in (pirate_weather, google) and not key:
            snap["errors"][name] = "no API key"
            continue
        try:
            snap["sources"].update(fn(key) if key else fn())
        except Exception as e:  # keep logging the others
            msg = str(e)
            if hasattr(e, "read"):  # HTTP error: keep the service's own reason
                try:
                    msg += " " + " ".join(e.read().decode(errors="replace").split())[:400]
                except Exception:
                    pass
            if key:
                msg = msg.replace(key.strip(), "***")
            if key:
                msg = msg.replace(key, "***")
            snap["errors"][name] = msg[:500]
    with open(path, "a") as f:
        f.write(json.dumps(snap, separators=(",", ":")) + "\n")
    print(f"logged {len(snap['sources'])} sources; errors: {snap['errors'] or 'none'}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "forecast-log.jsonl")
