#!/usr/bin/env python3
"""Save one snapshot of ensemble rain chances at airports around the world, to score later.

The app's chance of rain is Open-Meteo's best-match number, nudged by how many of the blend's
models are wet (RelayExtrasProvider.calibratingEnsemblePop). Ensembles run each model 20-64
times with small changes, so the share of runs that are wet is a direct chance of rain. Open-Meteo
keeps ensemble members for only three days, so they can't be scored on past data: this saves
them as they come, and tools/score_ensembles.py scores them against airport reports later.

Each snapshot (one gzip JSON file in the log folder) holds, per airport and for the next 120 hours:
  bm_pop   best-match chance of rain (%), what the app starts from
  bm_mm    best-match precipitation (mm)
  blend    {model: mm} for each blend model of the airport's region (the app's model share)
  ens      {ensemble model: wet share (%) of members with >= 0.2 mm in the hour}

Run by .github/workflows/ensemble-log.yml every 6 hours.

  python3 log_ensembles.py LOG_DIR
"""
import gzip, json, os, sys, threading, time, urllib.error, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from score_regions import STATIONS, region_of  # noqa: E402

FAMILY = ["KHIO", "KORL", "KSFB", "EGLC", "CYHM", "KPDX"]   # airports near family places
HOURS = 120
WET_MM = 0.2        # ModelBlend.wetHourMm
# Ensemble ids to try; the ones Open-Meteo doesn't know are dropped on each run (and noted).
ENSEMBLES = ["ecmwf_ifs025", "ecmwf_aifs025", "gfs025", "icon_seamless", "gem_global",
             "ukmo_global_ensemble_20km", "google_weathernext2_ensemble", "ncep_aigefs025"]
PACE = float(os.environ.get("ENS_PACE", "0.25"))   # seconds per Open-Meteo call unit

_lock = threading.Lock()
_slot = [0.0]


def pace(units):
    with _lock:
        now = time.time()
        wait = max(0.0, _slot[0] - now)
        _slot[0] = max(now, _slot[0]) + PACE * units
    if wait:
        time.sleep(wait)


def get(url, units=1.0):
    for attempt in range(3):
        if "open-meteo" in url:
            pace(units)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:200]
            if e.code == 400:
                return {"error": msg}
            print("  HTTP", e.code, msg[:120], file=sys.stderr, flush=True)
            time.sleep(30 * (attempt + 1) if e.code == 429 else 5)
        except Exception as e:
            print("  retry", attempt, e, file=sys.stderr, flush=True)
            time.sleep(5 * (attempt + 1))
    return None


def stations(log_dir):
    """{icao: (lat, lon)}, kept in the log folder after the first run."""
    path = os.path.join(log_dir, "stations.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    ids = STATIONS + FAMILY
    out = {}
    for i in range(0, len(ids), 40):
        chunk = ids[i:i + 40]
        d = get("https://aviationweather.gov/api/data/stationinfo?" +
                urllib.parse.urlencode({"ids": ",".join(chunk), "format": "json"})) or []
        for s in d if isinstance(d, list) else []:
            sid = s.get("icaoId") or s.get("id")
            if sid and s.get("lat") is not None:
                out[sid] = (round(float(s["lat"]), 4), round(float(s["lon"]), 4))
    with open(path, "w") as f:
        json.dump(out, f, indent=0)
    return out


def blend_models(lat, lon):
    with open(os.path.join(HERE, "..", "Packages", "WeatherCore", "blend-regions.json")) as f:
        table = json.load(f)
    rid = region_of(lat, lon)
    names = next((r["models"] for r in table["regions"] if r["id"] == rid), table["global"]["models"])
    from score_regions import NAMES
    ids = {v: k for k, v in NAMES.items()}
    return [ids[n] for n in names if n in ids]


def hours_from(times, now):
    start = next((i for i, t in enumerate(times) if t >= now - 3600), None)
    return start


def forecast(lat, lon, now):
    models = blend_models(lat, lon)
    base = {"latitude": lat, "longitude": lon, "timezone": "GMT", "timeformat": "unixtime",
            "forecast_days": 6}
    bm = get("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(
        {**base, "hourly": "precipitation_probability,precipitation"}), 1)
    bl = get("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(
        {**base, "hourly": "precipitation", "models": ",".join(models)}), max(1, len(models) / 10))
    out = {}
    if bm and "hourly" in bm:
        h = bm["hourly"]
        i = hours_from(h["time"], now)
        if i is not None:
            out["t0"] = h["time"][i]
            out["bm_pop"] = h["precipitation_probability"][i:i + HOURS]
            out["bm_mm"] = h["precipitation"][i:i + HOURS]
    if bl and "hourly" in bl and "t0" in out:
        h = bl["hourly"]
        i = h["time"].index(out["t0"]) if out["t0"] in h["time"] else None
        if i is not None:
            out["blend"] = {m: h.get(f"precipitation_{m}", [])[i:i + HOURS] for m in models}
    return out


def ensemble(lat, lon, model, t0):
    q = {"latitude": lat, "longitude": lon, "timezone": "GMT", "timeformat": "unixtime",
         "forecast_days": 6, "hourly": "precipitation", "models": model}
    d = get("https://ensemble-api.open-meteo.com/v1/ensemble?" + urllib.parse.urlencode(q), 6)
    if not d or "hourly" not in d:
        return None, (d or {}).get("error", "no answer")
    h = d["hourly"]
    if t0 not in h["time"]:
        return None, "no hours"
    i = h["time"].index(t0)
    members = [k for k in h if k == "precipitation" or k.startswith("precipitation_member")]
    wet = []
    for j in range(i, min(i + HOURS, len(h["time"]))):
        vals = [h[k][j] for k in members if h[k][j] is not None]
        wet.append(round(100 * sum(v >= WET_MM for v in vals) / len(vals)) if vals else None)
    return {"wet": wet, "n": len(members)}, None


def main():
    log_dir = sys.argv[1]
    os.makedirs(log_dir, exist_ok=True)
    now = int(time.time())
    places = stations(log_dir)
    print(f"{len(places)} airports", flush=True)
    # Which ensemble ids work today (one cheap call each).
    lat, lon = places.get("CYYZ", (43.68, -79.63))
    live, dead = [], {}
    for m in ENSEMBLES:
        q = {"latitude": lat, "longitude": lon, "hourly": "precipitation", "models": m, "forecast_days": 1}
        d = get("https://ensemble-api.open-meteo.com/v1/ensemble?" + urllib.parse.urlencode(q), 1)
        if d and "hourly" in d:
            live.append(m)
        else:
            dead[m] = (d or {}).get("error", "no answer")[:120]
    print("ensembles:", live, "missing:", dead, flush=True)

    def one(item):
        icao, (la, lo) = item
        rec = forecast(la, lo, now)
        if "t0" not in rec:
            return icao, None
        rec["ens"] = {}
        for m in live:
            e, err = ensemble(la, lo, m, rec["t0"])
            if e:
                rec["ens"][m] = e
        return icao, rec

    out = {}
    with ThreadPoolExecutor(4) as ex:
        for icao, rec in ex.map(one, sorted(places.items())):
            if rec:
                out[icao] = rec
    snap = {"fetched": now, "ensembles": live, "missing": dead, "stations": out}
    name = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d%H") + ".json.gz"
    with gzip.open(os.path.join(log_dir, name), "wt") as f:
        json.dump(snap, f, separators=(",", ":"))
    print(f"saved {name}: {len(out)} airports, {sum(len(r['ens']) for r in out.values())} ensemble series")


if __name__ == "__main__":
    main()
