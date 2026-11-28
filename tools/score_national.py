#!/usr/bin/env python3
"""Score free national forecast sources against the app's blend, region by region.

The app's blend (Packages/WeatherCore/blend-regions.json) was fitted by tools/score_regions.py.
This script asks whether any other free source makes it better anywhere:

- More national models on Open-Meteo's Single Runs archive that the blend doesn't use yet
  (CANDIDATES: Australia's BoM ACCESS-G, Korea's KMA, Japan's JMA GSM, China's CMA, Italy's ARPAE,
  MeteoSwiss, Canada's RDPS, NOAA's AI GFS, ...). A model whose archive is empty is just skipped.
- NOAA's station forecasts (MOS) for US airports, from the Iowa Environmental Mesonet archive:
  GFS MOS, GFS extended MOS, LAMP and the National Blend's station text (NBS). These are made
  for the airport itself, so a win there only holds right next to an airport.

Set-up as in score_regions.py: the ~65 airports' METARs, single runs every EVERY days
alternating 00/12 UTC, app opened at run + 5 h, six day rows. For each region and day row:
  app      = the app's weights as they are now
  refit    = weights refitted over the app's models only (held out by airport)
  +source  = weights refitted over the app's models plus that one source (held out by airport)
all scored on the same hours (the hours the source covers). A source "wins" a day row only when
+source beats both app and refit by at least 1% held out. Weights are never fitted to one place:
every score is on airports left out of the fit, and a region needs MIN_STATIONS airports.

Writes national-report.json and prints a report.

  python3 score_national.py
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

import score_regions as sr

START = date.fromisoformat(os.environ.get("NAT_START", "2026-04-04"))
END = date.fromisoformat(os.environ.get("NAT_END", "2026-11-20"))
EVERY = int(os.environ.get("NAT_EVERY", "5"))
DAYS = 6
TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "WeatherCore", "blend-regions.json")

NAMES = dict(sr.NAMES, metno_seamless="norway")
IDS = {v: k for k, v in NAMES.items()}

# Open-Meteo models to try, per region ("*" = everywhere). Probed 2026-11-28 (probe_national.py).
# BoM's ACCESS-G and Korea's KMA have no Single Runs archive (logged live by log_national.py
# instead); models that are already inside a "seamless" one the app uses (ICON-D2/EU, AROME,
# HARMONIE) aren't tried on their own.
CANDIDATES = json.loads(os.environ.get("NAT_CANDIDATES", "{}")) or {
    "*": ["ncep_aigfs025", "cma_grapes_global", "jma_gsm"],
    "na_east": ["gem_regional", "ncep_rrfs_conus"],
    "na_west": ["gem_regional", "ncep_rrfs_conus"],
    "europe": ["italia_meteo_arpae_icon_2i", "meteoswiss_icon_seamless", "metno_nordic"],
    "east_asia": ["jma_msm"],
}
# IEM MOS products at North American airports (the National Blend's station text covers
# Canadian airports too). Each is taken from the 00/12 UTC run, out well before the app opens
# at run + 5 h (LAMP and the NBM really run every hour or more often, so this is a little
# unfair to them, never to the blend).
MOS = {
    "mos_gfs": "GFS",      # GFS MOS (MAV), 3-hourly to 72 h
    "mos_gfsx": "MEX",     # GFS extended MOS, to 8 days
    "mos_lamp": "LAV",     # GFS LAMP, hourly to 25 h
    "mos_nbs": "NBS",      # National Blend station text, to 72 h
    "mos_nbe": "NBE",      # National Blend extended station text, to 8 days
}
MOS_SKIP = set()           # (station, model) the archive doesn't have
EXTRA_STATIONS = os.environ.get("NAT_EXTRA_STATIONS", "KHIO,KPDX,KMCO,KSFB").split(",")
MIN_STATIONS = sr.MIN_STATIONS
WIN = 0.99


def table():
    t = json.load(open(TABLE))
    regs = {r["id"]: r for r in t["regions"]}
    regs["global"] = t["global"]
    return regs


def f_to_c(v):
    return (v - 32) * 5 / 9


def iem_json(url, name):
    """Cached GET; a 404 (no such station/run) is cached as empty too."""
    path = os.path.join(sr.CACHE, name)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    os.makedirs(sr.CACHE, exist_ok=True)
    d = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "weather-verify/1.0"})
            with urllib.request.urlopen(req, timeout=40) as r:
                d = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code in (404, 422):
                d = {}
                break
            time.sleep(10 * (attempt + 1))
        except Exception:
            time.sleep(10 * (attempt + 1))
    if d is not None:
        with open(path, "w") as f:
            json.dump(d, f)
    return d or {}


def mos_series(icao, model, runtime):
    """{UTC hour 'YYYY-MM-DDTHH:00': °C} from one MOS run at one station, or {}."""
    if (icao, model) in MOS_SKIP:
        return {}
    q = {"station": icao, "model": model, "runtime": runtime.strftime("%Y-%m-%d %H:00Z")}
    url = "https://mesonet.agron.iastate.edu/api/1/mos.json?" + urllib.parse.urlencode(q)
    d = iem_json(url, f"mos-{icao}-{model}-{runtime:%Y%m%d%H}.json")
    rows = d.get("data", []) if isinstance(d, dict) else []
    out = {}
    for r in rows:
        ft, v = r.get("ftime"), r.get("tmp")
        if ft is None or v is None:
            continue
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        if v > 900:
            continue
        ts = ft.replace(" ", "T")[:13] + ":00"
        out[ts] = f_to_c(v)
    return out


def main():
    regs = table()
    stations = []
    for icao in sr.STATIONS + [s for s in EXTRA_STATIONS if s]:
        obs, lat, lon = sr.metars(icao)
        if len(obs) < 1500 or lat is None:
            print(f"{icao}: only {len(obs)} reports, skipped", file=sys.stderr, flush=True)
            continue
        stations.append((icao, lat, lon, sr.region_of(lat, lon), obs))
    if os.environ.get("NAT_STAGE") == "obs":
        return

    runs = []
    d, k = START, 0
    while d <= END:
        runs.append(datetime(d.year, d.month, d.day, 0 if k % 2 == 0 else 12))
        d += timedelta(days=EVERY)
        k += 1

    rows = defaultdict(list)       # (icao, day) -> [{model: err}]
    seen = defaultdict(int)        # source -> scored hours
    for icao, lat, lon, reg, obs in stations:
        app = regs.get(reg, regs["global"])
        app_ids = [IDS[m] for m in app["models"]]
        na = sr.in_north_america(lat, lon)
        cands = CANDIDATES.get("*", []) + CANDIDATES.get(reg, [])
        # Same call as score_regions.py (its cache is reused), then the app's other models and
        # each candidate in calls of their own (one missing run fails a whole call).
        core = sr.CORE + (sr.NA_HIRES if na else []) + sr.EXTRAS.get(reg, sr.DEFAULT_EXTRAS)
        rest = [m for m in app_ids if m not in core]

        def load(run):
            s = sr.single_run(lat, lon, core, run, icao, 7)
            for m in rest + cands:
                s.update(sr.single_run(lat, lon, [m], run, icao, 7))
            if na:
                for name, model in MOS.items():
                    ms = mos_series(icao, model, run)
                    if ms:
                        s[name] = ms
            return run, s

        # A station the archive has no MOS for at all: don't ask for every run.
        if na:
            for name, model in MOS.items():
                if not mos_series(icao, model, datetime(2026, 10, 1, 0)) and not mos_series(icao, model, datetime(2026, 6, 1, 12)):
                    MOS_SKIP.add((icao, model))
                    print(f"  {icao}: no {model}", file=sys.stderr, flush=True)

        with ThreadPoolExecutor(3) as pool:
            for run, series in pool.map(load, runs):
                issue = run + timedelta(hours=sr.ISSUE_DELAY)
                for lead in range(24 * DAYS):
                    t = (issue + timedelta(hours=lead)).strftime("%Y-%m-%dT%H:00")
                    o = obs.get(t)
                    if o is None:
                        continue
                    e = {m: s[t] - o for m, s in series.items() if t in s}
                    day = lead // 24
                    if na and day <= 1:
                        e.pop("gfs_seamless", None)
                    if sum(m in e for m in app_ids) >= 3:
                        rows[(icao, day)].append(e)
                        for m in e:
                            seen[m] += 1
        print(f"  {icao} {reg}: {sum(len(rows[(icao, n)]) for n in range(DAYS))} hours", file=sys.stderr, flush=True)

    by_region = defaultdict(list)
    for icao, lat, lon, reg, obs in stations:
        by_region[reg].append(icao)

    report = {"period": [START.isoformat(), END.isoformat()], "every_days": EVERY, "hours_per_source": dict(seen),
              "regions": {}}

    def fit_on(rows_, members):
        sr.ALL = members
        sr.STATS.clear()
        st = sr.stats(rows_)
        S, N, cover, n = st
        mem = [m for i, m in enumerate(members) if n and cover[i] >= sr.COVER * n]
        return sr.fit(st, mem) if mem else {}

    for reg, icaos in sorted(by_region.items()):
        app = regs.get(reg, regs["global"])
        app_ids = [IDS[m] for m in app["models"]]
        res = {"stations": icaos, "days": []}
        for n in range(DAYS):
            app_w = {IDS[m]: w for m, w in app["byDay"][n].items()}
            srcs = sorted({m for s in icaos for e in rows[(s, n)] for m in e} - set(app_ids))
            day = {}
            for src in srcs:
                with_src = {s: [e for e in rows[(s, n)] if src in e] for s in icaos}
                have = [s for s in icaos if len(with_src[s]) >= 50]
                if not have:
                    continue
                tot = {"app": 0.0, "refit": 0.0, "plus": 0.0, "alone": 0.0}
                hours = 0
                held = len(have) >= MIN_STATIONS
                for s in have:
                    test = with_src[s]
                    train = [e for x in have if x != s for e in with_src[x]] if held else []
                    w_refit = fit_on(train, app_ids) if held else app_w
                    w_plus = fit_on(train, app_ids + [src]) if held else {}
                    hn = len(test)
                    hours += hn
                    tot["app"] += sr.mae(test, app_w) * hn
                    tot["refit"] += sr.mae(test, w_refit) * hn
                    tot["alone"] += sum(abs(e[src]) for e in test)
                    if held:
                        tot["plus"] += sr.mae(test, w_plus) * hn
                r = {k: round(v / hours, 3) for k, v in tot.items() if v or k != "plus"}
                r["hours"] = hours
                r["stations"] = len(have)
                r["bias"] = round(sum(e[src] for s in have for e in with_src[s]) / hours, 3)
                if held:
                    allw = fit_on([e for s in have for e in with_src[s]], app_ids + [src])
                    r["weight"] = round(allw.get(src, 0.0), 3)
                    r["weights"] = {NAMES.get(m, m): round(w, 3) for m, w in allw.items()}
                    r["wins"] = r["plus"] < min(r["app"], r["refit"]) * WIN
                day[src] = r
            res["days"].append(day)
        report["regions"][reg] = res

    with open("national-report.json", "w") as f:
        json.dump(report, f, indent=1)
    print("hours per source:", json.dumps(dict(sorted(seen.items()))))
    for reg, res in report["regions"].items():
        print(f"\n## {reg} ({len(res['stations'])} airports)")
        for n, day in enumerate(res["days"]):
            for src, r in sorted(day.items()):
                flag = "WIN" if r.get("wins") else "   "
                print(f"  day{n} {flag} {src:28s} app={r['app']:.3f} refit={r['refit']:.3f} "
                      f"plus={r.get('plus', float('nan')):.3f} alone={r['alone']:.3f} bias={r['bias']:+.2f} "
                      f"w={r.get('weight', '-')} n={r['hours']} st={r['stations']}")
    print("\nNATIONAL-REPORT-JSON")
    print(json.dumps(report["regions"]))


if __name__ == "__main__":
    main()
