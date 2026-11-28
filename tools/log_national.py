#!/usr/bin/env python3
"""Log live forecasts from free national weather services that keep no public archive, so they
can be scored later against airport observations (tools/score_national_forward.py).

Each snapshot, at airports around the world (near the family's places and a spread elsewhere):
- om:<model>  the Open-Meteo models the app's blend uses in that region (the comparison baseline),
              plus national models Open-Meteo keeps no archive of (LIVE_ONLY: Australia's BoM
              ACCESS-G, Korea's KMA)
- nws         US National Weather Service gridded forecast (forecasters' edit of the National Blend)
- metno       MET Norway locationforecast (yr.no)
- mosmix      DWD MOSMIX-L station forecast, where the airport has a MOSMIX station
- metoffice   UK Met Office global spot forecast (only when MET_OFFICE_KEY is set; free tier
              is 360 calls a day, so only METOFFICE_MAX airports per snapshot)

Rows go to <dir>/YYYY-MM-DD.jsonl.gz, one per (snapshot, airport, source):
  {"t": issue unix, "st": ICAO, "src": name, "h": [[hour unix, °C], ...]}  (next 144 hours)

  python3 log_national.py <dir>
"""
import gzip, io, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request, zipfile
from datetime import datetime, timezone

UA = "weather-verify/1.0"
HOURS = 144
TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "WeatherCore", "blend-regions.json")
IDS = {"canada": "gem_seamless", "canadaHighRes": "gem_hrdps_continental", "us": "gfs_seamless",
       "usHighRes": "gfs_hrrr", "europe": "ecmwf_ifs025", "uk": "ukmo_seamless", "germany": "icon_seamless",
       "europeAI": "ecmwf_aifs025_single", "usBlend": "ncep_nbm_conus", "europeHighRes": "ecmwf_ifs",
       "france": "meteofrance_seamless", "netherlands": "knmi_seamless", "denmark": "dmi_seamless",
       "norway": "metno_seamless", "japan": "jma_seamless"}
# ICAO, lat, lon (airport reference points). Family places first: Milton/Oakville/Mississauga
# (CYYZ, CYHM, CYTZ), Hillsboro/North Plains (KHIO, KPDX), Altamonte Springs (KORL, KSFB, KMCO),
# London (EGLL, EGLC), Lahore (OPLA).
AIRPORTS = [
    ("CYYZ", 43.677, -79.631), ("CYHM", 43.173, -79.935), ("CYTZ", 43.628, -79.396),
    ("KHIO", 45.540, -122.950), ("KPDX", 45.589, -122.597), ("KORL", 28.545, -81.333),
    ("KSFB", 28.778, -81.237), ("KMCO", 28.429, -81.309), ("EGLL", 51.478, -0.461),
    ("EGLC", 51.505, 0.055), ("OPLA", 31.522, 74.404),
    ("CYOW", 45.322, -75.667), ("CYUL", 45.468, -73.741), ("CYVR", 49.195, -123.184),
    ("CYYC", 51.131, -114.010), ("KORD", 41.979, -87.905), ("KBOS", 42.363, -71.006),
    ("KATL", 33.637, -84.428), ("KDCA", 38.852, -77.037), ("KMSP", 44.882, -93.222),
    ("KDFW", 32.897, -97.038), ("KMIA", 25.795, -80.290), ("KTPA", 27.976, -82.533),
    ("KSEA", 47.449, -122.309), ("KSFO", 37.619, -122.375), ("KLAX", 33.942, -118.408),
    ("KPHX", 33.434, -112.012), ("KDEN", 39.856, -104.674), ("KSLC", 40.788, -111.978),
    ("EGCC", 53.354, -2.275), ("EGBB", 52.454, -1.748), ("EIDW", 53.421, -6.270),
    ("LFPG", 49.010, 2.548), ("EDDF", 50.033, 8.571), ("EHAM", 52.309, 4.764),
    ("LEMD", 40.472, -3.561), ("LIRF", 41.800, 12.239), ("ESSA", 59.652, 17.919),
    ("EPWA", 52.166, 20.967), ("OPIS", 33.549, 72.825), ("OPKC", 24.907, 67.161),
    ("VIDP", 28.566, 77.103), ("VABB", 19.089, 72.868), ("OMDB", 25.253, 55.365),
    ("RJTT", 35.552, 139.780), ("RKSI", 37.469, 126.451), ("VHHH", 22.309, 113.915),
    ("YSSY", -33.946, 151.177), ("YMML", -37.673, 144.843), ("NZAA", -37.008, 174.792),
]
LIVE_ONLY = ["bom_access_global", "kma_seamless"]
METOFFICE_MAX = int(os.environ.get("METOFFICE_MAX", "14"))
REGIONS = [("na_east", [[24, 75, -100, -50]]), ("na_west", [[24, 75, -170, -100]]),
           ("europe", [[34, 72, -25, 45]]), ("sw_asia", [[5, 45, 34, 92]]),
           ("east_asia", [[18, 55, 92, 150]]), ("oceania", [[-50, -8, 110, 180]])]


def region_of(lat, lon):
    for rid, boxes in REGIONS:
        for a, b, c, d in boxes:
            if a <= lat <= b and c <= lon <= d:
                return rid
    return "global"


def get(url, headers=None, binary=False, tries=3):
    h = {"User-Agent": UA, "Accept": "application/geo+json, application/json, */*"}
    h.update(headers or {})
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=45) as r:
                b = r.read()
                return b if binary else json.loads(b)
        except urllib.error.HTTPError as e:
            print(f"  HTTP {e.code} {url[:120]}", file=sys.stderr, flush=True)
            if e.code in (400, 401, 403, 404):
                return None
        except Exception as e:
            print(f"  retry {i} {url[:100]}: {e}", file=sys.stderr, flush=True)
        time.sleep(5 * (i + 1))
    return None


def iso_hour(s):
    s = s.replace("Z", "+00:00")
    return int(datetime.fromisoformat(s).timestamp()) // 3600 * 3600


def clip(pairs, now):
    end = now + HOURS * 3600
    return sorted([[t, round(v, 2)] for t, v in pairs if now - 3600 <= t <= end and v is not None])


def open_meteo(lat, lon, models):
    q = {"latitude": lat, "longitude": lon, "hourly": "temperature_2m", "models": ",".join(models),
         "timezone": "GMT", "forecast_days": 7, "timeformat": "unixtime"}
    d = get("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q))
    out = {}
    if not d and len(models) > 1:      # one model failing fails the call: ask one by one
        for m in models:
            out.update(open_meteo(lat, lon, [m]))
        return out
    if not d:
        return out
    h = d.get("hourly", {})
    for m in models:
        vals = h.get(f"temperature_2m_{m}" if len(models) > 1 else "temperature_2m") or []
        out["om:" + m] = list(zip(h.get("time", []), vals))
    return out


NWS_GRID = {}


def nws(icao, lat, lon, cache):
    url = cache.get(icao)
    if not url:
        p = get(f"https://api.weather.gov/points/{lat:.4f},{lon:.4f}")
        if not p:
            return None
        url = p["properties"]["forecastGridData"]
        cache[icao] = url
    g = get(url)
    if not g:
        return None
    temp = g["properties"]["temperature"]
    out = []
    for v in temp["values"]:
        start, dur = v["validTime"].split("/")
        t0 = iso_hour(start)
        m = re.match(r"P(?:(\d+)D)?T?(?:(\d+)H)?", dur)
        hours = (int(m.group(1) or 0) * 24 + int(m.group(2) or 0)) if m else 1
        val = v["value"]
        if temp.get("uom", "").endswith("degF") and val is not None:
            val = (val - 32) * 5 / 9
        for k in range(max(hours, 1)):
            out.append((t0 + 3600 * k, val))
    return out


def metno(lat, lon):
    d = get(f"https://api.met.no/weatherapi/locationforecast/2.0/compact?lat={lat:.4f}&lon={lon:.4f}")
    if not d:
        return None
    out = []
    for s in d["properties"]["timeseries"]:
        out.append((iso_hour(s["time"]), s["data"]["instant"]["details"].get("air_temperature")))
    return out


def mosmix_catalogue(cache):
    if cache.get("_loaded"):
        return cache
    raw = get("https://www.dwd.de/DE/leistungen/met_verfahren_mosmix/mosmix_stationskatalog.cfg?view=nasPublication&nn=16102", binary=True)
    if raw:
        for line in raw.decode("latin-1").splitlines():
            parts = line.split()
            if len(parts) >= 3 and re.fullmatch(r"\d{5}|[A-Z0-9]{4,5}", parts[0]) and re.fullmatch(r"[A-Z]{4}", parts[1]):
                cache[parts[1]] = parts[0]
        cache["_loaded"] = True
    return cache


def mosmix(sid):
    b = get(f"https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/single_stations/{sid}/kml/MOSMIX_L_LATEST_{sid}.kmz", binary=True)
    if not b:
        return None
    z = zipfile.ZipFile(io.BytesIO(b))
    x = z.read(z.namelist()[0]).decode("utf-8", "replace")
    times = re.findall(r"<dwd:TimeStep>([^<]+)</dwd:TimeStep>", x)
    m = re.search(r'elementName="TTT">\s*<dwd:value>([^<]+)</dwd:value>', x)
    if not times or not m:
        return None
    vals = m.group(1).split()
    out = []
    for t, v in zip(times, vals):
        try:
            out.append((iso_hour(t), float(v) - 273.15))
        except ValueError:
            continue
    return out


def metoffice(lat, lon, key):
    d = get(f"https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/hourly?latitude={lat:.4f}&longitude={lon:.4f}",
            headers={"apikey": key, "accept": "application/json"})
    if not d:
        return None
    out = []
    for s in d["features"][0]["properties"]["timeSeries"]:
        out.append((iso_hour(s["time"]), s.get("screenTemperature")))
    return out


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    state_path = os.path.join(outdir, "state.json")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    nws_cache = state.setdefault("nws_grid", {})
    mx_cache = state.setdefault("mosmix", {})
    table = json.load(open(TABLE))
    regs = {r["id"]: r for r in table["regions"]}
    now = int(time.time()) // 3600 * 3600
    mo_key = os.environ.get("MET_OFFICE_KEY", "")
    mo_used = 0
    rows = []
    counts = {}
    if not mx_cache.get("_loaded"):
        mosmix_catalogue(mx_cache)
    for icao, lat, lon in AIRPORTS:
        reg = region_of(lat, lon)
        models = [IDS[m] for m in regs.get(reg, table["global"])["models"]] + LIVE_ONLY
        series = open_meteo(lat, lon, models)
        if icao.startswith("K"):
            s = nws(icao, lat, lon, nws_cache)
            if s:
                series["nws"] = s
        s = metno(lat, lon)
        if s:
            series["metno"] = s
        sid = mx_cache.get(icao)
        if sid:
            s = mosmix(sid)
            if s:
                series["mosmix"] = s
        if mo_key and mo_used < METOFFICE_MAX:
            mo_used += 1
            s = metoffice(lat, lon, mo_key)
            if s:
                series["metoffice"] = s
        for src, pairs in series.items():
            h = clip(pairs, now)
            if h:
                rows.append({"t": now, "st": icao, "src": src, "h": h})
                counts[src.split(":")[0]] = counts.get(src.split(":")[0], 0) + 1
        time.sleep(0.5)
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    with gzip.open(os.path.join(outdir, f"{day}.jsonl.gz"), "at") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
    with open(state_path, "w") as f:
        json.dump(state, f, indent=0, sort_keys=True)
    print(f"snapshot {day} {now}: {len(rows)} rows", counts)


if __name__ == "__main__":
    main()
