#!/usr/bin/env python3
"""Append one snapshot of hourly forecasts for Milton to a JSON-lines log.

Run every few hours by .github/workflows/forecast-log.yml. Each line holds the time the
forecast was fetched and, per source, the next 120 hours of temperature (°C), precipitation
(mm/h) and precipitation probability (%). tools/score_forecast_log.py later scores the
snapshots against Environment Canada observations by lead time.

Sources: Open-Meteo (each model the app blends, so the blend can be rebuilt offline),
Pirate Weather (PIRATE_WEATHER_KEY) and Tomorrow.io (TOMORROW_IO_KEY). A source whose key is
missing or whose request fails is recorded with its error and skipped.
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


def tomorrow_io(key):
    q = urllib.parse.urlencode({"location": f"{LAT},{LON}", "timesteps": "1h", "units": "metric", "apikey": key})
    rows = get("https://api.tomorrow.io/v4/weather/forecast?" + q)["timelines"]["hourly"][:HOURS]
    out = []
    for r in rows:
        v = r["values"]
        t = dt.datetime.fromisoformat(r["time"].replace("Z", "+00:00")).timestamp()
        rate = sum(v.get(k) or 0 for k in ("rainIntensity", "sleetIntensity", "freezingRainIntensity")) \
            + (v.get("snowIntensity") or 0) / 10   # snow is reported as cm/h of snow; ~10:1 to water
        out.append([hour_key(t), v.get("temperature"), round(rate, 2), v.get("precipitationProbability")])
    return {"tomorrow": out}


def main(path):
    snap = {"fetched": int(dt.datetime.now(dt.timezone.utc).timestamp()), "sources": {}, "errors": {}}
    jobs = [("open-meteo", open_meteo, None),
            ("pirate", pirate_weather, os.environ.get("PIRATE_WEATHER_KEY")),
            ("tomorrow", tomorrow_io, os.environ.get("TOMORROW_IO_KEY"))]
    for name, fn, key in jobs:
        if fn is not open_meteo and not key:
            snap["errors"][name] = "no API key"
            continue
        try:
            snap["sources"].update(fn(key) if key else fn())
        except Exception as e:  # keep logging the others
            msg = str(e)
            if key:
                msg = msg.replace(key, "***")
            snap["errors"][name] = msg[:300]
    with open(path, "a") as f:
        f.write(json.dumps(snap, separators=(",", ":")) + "\n")
    print(f"logged {len(snap['sources'])} sources; errors: {snap['errors'] or 'none'}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "forecast-log.jsonl")
