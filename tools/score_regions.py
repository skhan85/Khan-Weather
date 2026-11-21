#!/usr/bin/env python3
"""Score the blend's models at airports around the world and fit blend weights per region.

The blend's weights were first fitted at Toronto Pearson and Hamilton only. This script checks
them, and fits new ones, at about 60 airports on six continents:

- Observations: hourly METARs from the Iowa Environmental Mesonet archive (global, no key).
- Forecasts: Open-Meteo's Single Runs archive (from April 2026). As in tools/score_leads.py the
  app is taken to open at run + 5 h; every 5th day, alternating the 00 and 12 UTC runs. Lead
  hours 0-143 fill the six forecast-day rows of the blend.
- For each region (the boxes in REGIONS, the same ones the app uses) and each day row it fits
  weights over the models that cover that region, and checks them station by station: fitted
  on all the region's other airports and scored on the one left out. The region keeps its own
  weights only when that beats the worldwide weights (fitted the same way) at its airports.
- Against Open-Meteo's best_match (what the app shows outside North America today), via the
  Previous Runs archive for January, April and July 2026.

Writes region-weights.json (the table the app reads, see BlendRegions.swift) and
region-report.json, and prints a report.

  python3 score_regions.py
"""
import csv, io, json, math, os, sys, threading, time, urllib.error, urllib.parse, urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

CACHE = "verify-cache"
START = date.fromisoformat(os.environ.get("REGION_START", "2026-04-04"))
END = date.fromisoformat(os.environ.get("REGION_END", "2026-11-15"))
EVERY = int(os.environ.get("REGION_EVERY", "5"))      # days between sampled runs
ISSUE_DELAY = 5
DAYS = 6

CORE = ["gem_seamless", "gfs_seamless", "ecmwf_ifs025", "ecmwf_aifs025_single", "icon_seamless",
        "ukmo_seamless"]
NA_HIRES = ["gem_hrdps_continental", "gfs_hrrr"]
# Regional and newer models tried as well, asked for in their own call (so the core call's
# cache stays good): the US National Blend of Models, the national European models, Japan's and
# China's, and ECMWF's 9 km run.
EXTRAS = {
    "na_east": ["ncep_nbm_conus", "ecmwf_ifs"],
    "na_west": ["ncep_nbm_conus", "ecmwf_ifs"],
    "europe": ["meteofrance_seamless", "knmi_seamless", "dmi_seamless", "ecmwf_ifs"],
    "east_asia": ["jma_seamless", "cma_grapes_global", "ecmwf_ifs"],
}
DEFAULT_EXTRAS = ["ecmwf_ifs"]
EXTRA_MODELS = ["ncep_nbm_conus", "ecmwf_ifs", "meteofrance_seamless", "knmi_seamless", "dmi_seamless",
                "jma_seamless", "cma_grapes_global"]
COVER = 0.75            # share of a region's scored hours a model must cover to be weighted
NAMES = {"ncep_nbm_conus": "usBlend", "ecmwf_ifs": "europeHighRes", "meteofrance_seamless": "france",
         "knmi_seamless": "netherlands", "dmi_seamless": "denmark", "jma_seamless": "japan",
         "cma_grapes_global": "china",
         "gem_seamless": "canada", "gem_hrdps_continental": "canadaHighRes", "gfs_seamless": "us",
         "gfs_hrrr": "usHighRes", "ecmwf_ifs025": "europe", "ecmwf_aifs025_single": "europeAI",
         "icon_seamless": "germany", "ukmo_seamless": "uk"}

# Regions: id, name, boxes [latMin, latMax, lonMin, lonMax]. First match wins; else "global".
REGIONS = [
    ("na_east", "Eastern North America", [[24, 75, -100, -50]]),
    ("na_west", "Western North America", [[24, 75, -170, -100]]),
    ("europe", "Europe", [[34, 72, -25, 45]]),
    ("sw_asia", "Middle East and South Asia", [[5, 45, 34, 92]]),
    ("east_asia", "East Asia", [[18, 55, 92, 150]]),
    ("oceania", "Australia and New Zealand", [[-50, -8, 110, 180]]),
]
STATIONS = [
    # Eastern North America
    "CYYZ", "CYOW", "CYUL", "CYHZ", "CYWG", "KORD", "KBOS", "KATL", "KDCA", "KMSP", "KDFW", "KMIA",
    # Western North America
    "CYVR", "CYYC", "CYEG", "CYXE", "KSEA", "KSFO", "KLAX", "KPHX", "KDEN", "KSLC", "PANC",
    # Europe
    "EGLL", "EGCC", "EIDW", "LFPG", "EDDF", "EHAM", "LEMD", "LIRF", "ESSA", "EPWA", "LTFM",
    # Middle East and South Asia
    "OMDB", "OERK", "OTHH", "OJAI", "OPKC", "OPLA", "OPIS", "VIDP", "VABB",
    # East Asia
    "RJTT", "RJBB", "RKSI", "VHHH", "ZSPD", "RCTP",
    # Australia and New Zealand
    "YSSY", "YMML", "YBBN", "YPPH", "NZAA", "NZCH",
    # Elsewhere (global weights only)
    "SBGR", "SAEZ", "SCEL", "MMMX", "FAOR", "HECA", "HKJK", "WSSS", "VTBS",
]
MIN_STATIONS = 5        # fewer scored airports than this: the region uses the global weights
# The app's weights fitted at Pearson and Hamilton (ModelBlend.byDay before regions).
MILTON = [
    {"icon_seamless": 0.30, "ecmwf_ifs025": 0.20, "gfs_hrrr": 0.15, "gem_seamless": 0.15,
     "ukmo_seamless": 0.10, "ecmwf_aifs025_single": 0.10},
    {"ecmwf_aifs025_single": 0.28, "icon_seamless": 0.22, "ukmo_seamless": 0.185,
     "gem_hrdps_continental": 0.12, "gem_seamless": 0.10, "ecmwf_ifs025": 0.04, "gfs_hrrr": 0.025,
     "gfs_seamless": 0.025},
    {"ecmwf_aifs025_single": 0.35, "gfs_seamless": 0.23, "icon_seamless": 0.18, "ukmo_seamless": 0.125,
     "ecmwf_ifs025": 0.075, "gem_seamless": 0.04},
    {"ecmwf_aifs025_single": 0.43, "gfs_seamless": 0.235, "ukmo_seamless": 0.11, "icon_seamless": 0.095,
     "ecmwf_ifs025": 0.085, "gem_seamless": 0.045},
    {"ecmwf_aifs025_single": 0.47, "gfs_seamless": 0.23, "ukmo_seamless": 0.125, "ecmwf_ifs025": 0.075,
     "icon_seamless": 0.07, "gem_seamless": 0.03},
    {"ecmwf_aifs025_single": 0.49, "ecmwf_ifs025": 0.165, "gfs_seamless": 0.15, "ukmo_seamless": 0.08,
     "icon_seamless": 0.06, "gem_seamless": 0.055},
]
BM_MONTHS = ["2026-01", "2026-04", "2026-07"]
BM_LEADS = [0, 1, 3]


def region_of(lat, lon):
    for rid, _, boxes in REGIONS:
        for a, b, c, d in boxes:
            if a <= lat <= b and c <= lon <= d:
                return rid
    return "global"


def in_north_america(lat, lon):
    return region_of(lat, lon) in ("na_east", "na_west")


# ---------- fetching, cached and paced ----------
_lock = threading.Lock()
_next_slot = [0.0]
PACE = float(os.environ.get("REGION_PACE", "0.8"))   # seconds per Open-Meteo call unit
FAILS = defaultdict(int)


def pace(units):
    with _lock:
        now = time.time()
        wait = max(0.0, _next_slot[0] - now)
        _next_slot[0] = max(now, _next_slot[0]) + PACE * units
    if wait:
        time.sleep(wait)


def fetch(url, name, units=1.0, kind="json"):
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        with open(path) as f:
            if kind == "text":
                return f.read()
            d = json.load(f)
        return None if isinstance(d, dict) and "error" in d else d
    os.makedirs(CACHE, exist_ok=True)
    for attempt in range(4):
        if "open-meteo" in url:
            pace(units)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=90) as r:
                body = r.read().decode()
            with open(path, "w") as f:
                f.write(body)
            return body if kind == "text" else json.loads(body)
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:200]
            if e.code == 400:
                FAILS[msg] += 1
                if FAILS[msg] <= 3:
                    print("  400", msg, url[-160:], file=sys.stderr)
                with open(path, "w") as f:
                    json.dump({"error": msg}, f)
                return None
            print("  HTTP", e.code, msg[:120], file=sys.stderr, flush=True)
            time.sleep(60 * (attempt + 1) if e.code == 429 else 15 * (attempt + 1))
        except Exception as e:
            print("  retry", attempt, name, e, file=sys.stderr, flush=True)
            time.sleep(10 * (attempt + 1))
    return None


# ---------- observations ----------
def metars(icao):
    """({UTC hour 'YYYY-MM-DDTHH:00': temp °C}, lat, lon), the report nearest each hour (±20 min)."""
    q = {"station": icao, "data": "tmpc", "year1": 2026, "month1": 1, "day1": 1,
         "year2": END.year, "month2": END.month, "day2": END.day, "tz": "Etc/UTC",
         "format": "onlycomma", "latlon": "yes", "missing": "empty", "report_type": [3, 4]}
    url = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?" + urllib.parse.urlencode(q, doseq=True)
    body = fetch(url, f"iem-{icao}-{END}.csv", kind="text")
    if not body:
        return {}, None, None
    best = {}
    lat = lon = None
    for row in csv.DictReader(io.StringIO(body)):
        t = row.get("tmpc")
        if not t:
            continue
        try:
            v = float(t)
            ts = datetime.strptime(row["valid"], "%Y-%m-%d %H:%M")
            lat, lon = float(row["lat"]), float(row["lon"])
        except (ValueError, KeyError):
            continue
        if not -70 < v < 60:
            continue
        hour = (ts + timedelta(minutes=30)).replace(minute=0)
        off = abs((ts - hour).total_seconds()) / 60
        if off > 20:
            continue
        k = hour.strftime("%Y-%m-%dT%H:00")
        if k not in best or off < best[k][0]:
            best[k] = (off, v)
    return {k: v for k, (_, v) in best.items()}, lat, lon


# ---------- forecasts ----------
def single_run(lat, lon, models, run, tag, days):
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": "temperature_2m",
         "models": ",".join(models), "run": run.strftime("%Y-%m-%dT%H:%M"), "timezone": "GMT",
         "forecast_days": days}
    url = "https://single-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
    units = max(1.0, len(models) / 10) * max(1.0, days / 14)
    d = fetch(url, f"sr-{tag}-{run:%Y%m%d%H}-{days}-{'_'.join(models)}.json", units)
    if d is None:
        if len(models) > 1:   # one model's run missing fails the whole call: ask one by one
            out = {}
            for m in models:
                out.update(single_run(lat, lon, [m], run, tag, days))
            return out
        return {}
    h = d.get("hourly", {})
    times = h.get("time", [])
    out = {}
    for m in models:
        vals = h.get(f"temperature_2m_{m}" if len(models) > 1 else "temperature_2m") or []
        s = {t: v for t, v in zip(times, vals) if v is not None}
        if s:
            out[m] = s
    return out


def previous_runs(lat, lon, models, month, tag):
    a = date.fromisoformat(month + "-01")
    b = (a.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    vars_ = ["temperature_2m" if n == 0 else f"temperature_2m_previous_day{n}" for n in BM_LEADS]
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
         "models": ",".join(models), "timezone": "GMT", "start_date": a.isoformat(),
         "end_date": b.isoformat()}
    url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
    units = max(1.0, len(vars_) * len(models) / 10) * max(1.0, ((b - a).days + 1) / 14)
    d = fetch(url, f"pr-{tag}-{month}-{'_'.join(models)}.json", units)
    out = defaultdict(dict)     # (model, lead) -> {time: temp}
    if not d:
        return out
    h = d.get("hourly", {})
    times = h.get("time", [])
    for m in models:
        for n, v in zip(BM_LEADS, vars_):
            vals = h.get(f"{v}_{m}") or []
            out[(m, n)] = {t: x for t, x in zip(times, vals) if x is not None}
    return out


# ---------- fitting ----------
def simplex_min(C, iters=3000):
    """Minimise w'Cw over the simplex (exponentiated gradient)."""
    k = len(C)
    w = [1.0 / k] * k
    scale = max(C[i][i] for i in range(k)) or 1
    eta = 0.5 / scale
    for _ in range(iters):
        g = [2 * sum(C[i][j] * w[j] for j in range(k)) for i in range(k)]
        w = [w[i] * math.exp(-eta * g[i]) for i in range(k)]
        s = sum(w)
        w = [x / s for x in w]
    return w


ALL = CORE + NA_HIRES + EXTRA_MODELS
STATS = {}


def stats(rows):
    """Pairwise sums of error products over the rows where both models are present."""
    k = len(ALL)
    S = [[0.0] * k for _ in range(k)]
    N = [[0] * k for _ in range(k)]
    cover = [0] * k
    for e in rows:
        idx = [(i, e[m]) for i, m in enumerate(ALL) if m in e]
        for i, ei in idx:
            cover[i] += 1
            Si, Ni = S[i], N[i]
            for j, ej in idx:
                Si[j] += ei * ej
                Ni[j] += 1
    return S, N, cover, len(rows)


def station_stats(icao, day):
    key = (icao, day)
    if key not in STATS:
        STATS[key] = stats(ROWS[key])
    return STATS[key]


def pooled_stats(icaos, day):
    k = len(ALL)
    S = [[0.0] * k for _ in range(k)]
    N = [[0] * k for _ in range(k)]
    cover = [0] * k
    total = 0
    for s in icaos:
        a, b, c, n = station_stats(s, day)
        total += n
        for i in range(k):
            cover[i] += c[i]
            for j in range(k):
                S[i][j] += a[i][j]
                N[i][j] += b[i][j]
    return S, N, cover, total


def members_of(st):
    _, _, cover, n = st
    return [m for i, m in enumerate(ALL) if n and cover[i] >= COVER * n]


def fit(st, mem=None):
    S, N, _, _ = st
    mem = mem or members_of(st)
    ix = [ALL.index(m) for m in mem]
    C = [[S[i][j] / max(N[i][j], 1) for j in ix] for i in ix]
    w = simplex_min(C)
    w = [x if x >= 0.02 else 0.0 for x in w]          # drop crumbs, then renormalise
    tot = sum(w)
    return {m: x / tot for m, x in zip(mem, w) if x > 0}


def blend_err(e, weights):
    ws = {m: w for m, w in weights.items() if m in e}
    s = sum(ws.values())
    if s <= 0:
        return sum(e.values()) / len(e)
    return sum(e[m] * w for m, w in ws.items()) / s


def mae(rows, weights):
    return sum(abs(blend_err(e, weights)) for e in rows) / max(len(rows), 1)


ROWS = defaultdict(list)


def main():
    stations = []
    for icao in STATIONS:
        obs, lat, lon = metars(icao)
        if len(obs) < 1500 or lat is None:
            print(f"{icao}: only {len(obs)} hourly reports, skipped", file=sys.stderr, flush=True)
            continue
        stations.append((icao, lat, lon, region_of(lat, lon), obs))
        print(f"{icao} {region_of(lat, lon)} {lat:.2f},{lon:.2f} {len(obs)} hours", file=sys.stderr, flush=True)
    if os.environ.get("REGION_STAGE") == "obs":
        return

    runs = []
    d, k = START, 0
    while d <= END:
        runs.append(datetime(d.year, d.month, d.day, 0 if k % 2 == 0 else 12))
        d += timedelta(days=EVERY)
        k += 1

    # rows[(station, dayrow)] = list of {model: forecast - observed}
    rows = ROWS
    for icao, lat, lon, reg, obs in stations:
        na = in_north_america(lat, lon)

        def load(run):
            models = CORE + (NA_HIRES if na else []) + EXTRAS.get(reg, DEFAULT_EXTRAS)
            return run, single_run(lat, lon, models, run, icao, 7)

        with ThreadPoolExecutor(3) as pool:
            for run, series in pool.map(load, runs):
                issue = run + timedelta(hours=ISSUE_DELAY)
                for lead in range(24 * DAYS):
                    t = (issue + timedelta(hours=lead)).strftime("%Y-%m-%dT%H:00")
                    o = obs.get(t)
                    if o is None:
                        continue
                    e = {m: s[t] - o for m, s in series.items() if t in s}
                    day = lead // 24
                    # Live, Open-Meteo's GFS id serves HRRR for the first two days in North
                    # America, so pure GFS isn't what the app would get there.
                    if na and day <= 1:
                        e.pop("gfs_seamless", None)
                    if len(e) >= 4:
                        rows[(icao, day)].append(e)
        print(f"  {icao}: {sum(len(rows[(icao, n)]) for n in range(DAYS))} scored hours", file=sys.stderr, flush=True)

    by_region = defaultdict(list)
    for icao, lat, lon, reg, obs in stations:
        by_region[reg].append(icao)

    report = {"period": [START.isoformat(), END.isoformat()], "every_days": EVERY,
              "stations": {s[0]: {"region": s[3], "lat": s[1], "lon": s[2]} for s in stations},
              "regions": {}}

    def pooled_rows(icaos, day):
        out = []
        for s in icaos:
            out += rows[(s, day)]
        return out

    # Worldwide weights: every airport, over the models that cover the whole world. North
    # America's high-resolution models and the regional ones fall out at the cover rule.
    all_icaos = [s[0] for s in stations]
    global_w = [fit(pooled_stats(all_icaos, n)) for n in range(DAYS)]
    # Worldwide weights fitted without each airport, for the held-out scores.
    global_wo = {(s, n): fit(pooled_stats([x for x in all_icaos if x != s], n))
                 for s in all_icaos for n in range(DAYS)}

    table = {"global": global_w}
    for rid, name, boxes in REGIONS + [("global", "Elsewhere", [])]:
        icaos = by_region.get(rid, [])
        res = {"name": name, "stations": icaos, "days": []}
        own = []
        wins = 0
        for n in range(DAYS):
            r = pooled_rows(icaos, n)
            if not r:
                own.append(global_w[n])
                res["days"].append({"hours": 0})
                continue
            st = pooled_stats(icaos, n)
            mem = members_of(st)
            w_all = fit(st, mem)
            # Leave one airport out: fit on the others in the region (and, for the worldwide
            # weights, on every other airport), score on the one left out.
            loso = {"region": [], "global": [], "milton": [], "equal": []}
            for s in icaos:
                test = rows[(s, n)]
                if not test:
                    continue
                rest = [x for x in icaos if x != s]
                if len(rest) >= MIN_STATIONS - 1:
                    loso["region"].append((len(test), mae(test, fit(pooled_stats(rest, n)))))
                loso["global"].append((len(test), mae(test, global_wo[(s, n)])))
                loso["milton"].append((len(test), mae(test, MILTON[n])))
                loso["equal"].append((len(test), mae(test, {m: 1 for m in mem})))
            day = {"hours": len(r), "members": mem,
                   "weights": {NAMES[m]: round(w, 3) for m, w in w_all.items()},
                   "single_mae": {NAMES[m]: round(sum(abs(e[m]) for e in r if m in e) / max(1, sum(m in e for e in r)), 3) for m in mem},
                   "single_bias": {NAMES[m]: round(sum(e[m] for e in r if m in e) / max(1, sum(m in e for e in r)), 3) for m in mem}}
            for k2, v in loso.items():
                if v:
                    day[f"held_out_{k2}"] = round(sum(a * b for a, b in v) / sum(a for a, _ in v), 3)
            res["days"].append(day)
            if "held_out_region" in day and day["held_out_region"] < day["held_out_global"] * 0.99:
                wins += 1
            own.append(w_all)
        # Keep the region's own weights only if they beat the worldwide ones on most days.
        res["own_weights"] = rid != "global" and len(icaos) >= MIN_STATIONS and wins >= 4
        res["days_won"] = wins
        if rid != "global":
            table[rid] = own if res["own_weights"] else global_w
        report["regions"][rid] = res

    # Against best_match (Previous Runs archive: each model's latest run as "day 0").
    bm = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0]))   # region -> lead -> [blend, bm, n]
    for icao, lat, lon, reg, obs in stations:
        na = in_north_america(lat, lon)
        models = CORE + (NA_HIRES if na else []) + EXTRAS.get(reg, DEFAULT_EXTRAS) + ["best_match"]
        weights = table.get(reg, global_w)
        for month in BM_MONTHS:
            pr = previous_runs(lat, lon, models, month, icao)
            for n in BM_LEADS:
                for t, b in pr.get(("best_match", n), {}).items():
                    o = obs.get(t)
                    if o is None:
                        continue
                    e = {m: pr[(m, n)][t] - o for m in models[:-1] if t in pr.get((m, n), {})}
                    if len(e) < 4:
                        continue
                    acc = bm[reg][n]
                    acc[0] += abs(blend_err(e, weights[n]))
                    acc[1] += abs(b - o)
                    acc[2] += 1
    for reg, leads in bm.items():
        res = report["regions"].setdefault(reg, {})
        res["vs_best_match"] = {f"day{n}": {"blend": round(a / c, 3), "best_match": round(b / c, 3), "hours": c}
                                for n, (a, b, c) in sorted(leads.items()) if c}
        # The blend replaces best_match only where it wins on most of the scored lead days.
        won = sum(1 for v in res["vs_best_match"].values() if v["blend"] < v["best_match"])
        res["blend_beats_best_match"] = won >= 2

    out = {"regions": [], "global": {"useBlend": report["regions"].get("global", {}).get("blend_beats_best_match", False),
                                     "byDay": [{NAMES[m]: round(w, 3) for m, w in d.items()} for d in global_w]}}
    for rid, name, boxes in REGIONS:
        rr = report["regions"].get(rid, {})
        out["regions"].append({"id": rid, "name": name, "boxes": boxes,
                               "ownWeights": rr.get("own_weights", False),
                               "useBlend": rr.get("blend_beats_best_match", False),
                               "byDay": [{NAMES[m]: round(w, 3) for m, w in d.items()} for d in table[rid]]})
    with open("region-weights.json", "w") as f:
        json.dump(out, f, indent=1)
    with open("region-report.json", "w") as f:
        json.dump(report, f, indent=1)

    for rid, res in report["regions"].items():
        print(f"\n## {rid} {res.get('name', '')} stations={res.get('stations')} own={res.get('own_weights')} "
              f"won={res.get('days_won')} beats_best_match={res.get('blend_beats_best_match')}")
        for n, day in enumerate(res.get("days", [])):
            if not day.get("hours"):
                continue
            print(f"  day{n} hours={day['hours']} held-out MAE region={day.get('held_out_region')} "
                  f"global={day.get('held_out_global')} milton={day.get('held_out_milton')} "
                  f"equal={day.get('held_out_equal')}")
            print(f"        weights={day['weights']}")
            print(f"        singles={day['single_mae']} bias={day['single_bias']}")
        for k2, v in res.get("vs_best_match", {}).items():
            print(f"  vs best_match {k2}: {v}")
    print("\nREGION-WEIGHTS-JSON")
    print(json.dumps(out))


if __name__ == "__main__":
    main()
