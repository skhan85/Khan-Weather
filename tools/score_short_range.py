#!/usr/bin/env python3
"""Score the next 12 hours the way the app really sees them, and fit short-range blend weights.

tools/score_regions.py scores every model from the same 00/12 UTC run opened five hours later.
That's fair for days 1-6 but not for the next few hours: live, the app gets whichever run of
each model is newest when it opens, and the high-resolution models that run every hour (HRRR,
the National Blend, the UK 2 km run inside ukmo_seamless, KNMI's HARMONIE) are then only an hour
or two old while ECMWF's newest run is often 7-13 hours old.

This script copies that:
- Opening times T spread over April-November 2026 and over all 24 hours of the day.
- For each model, the newest run that was out by T: the run cycle (every 1, 3, 6 or 12 h) and
  how long after the run it reaches Open-Meteo (CYCLES). If that run isn't in the Single Runs
  archive (say ukmo_seamless has no 07 UTC run outside the UK), the next older cycle is tried.
- Scored against airport METARs (the same ~65 airports as score_regions.py) at T+0 ... T+11 h,
  in three lead bands: 0-2, 3-5 and 6-11 h.
- For each region and band it fits weights and checks them airport by airport (fitted without
  the airport, scored on it), against the worldwide fit and against what the app uses now
  (the day-0 row of Packages/WeatherCore/blend-regions.json). A region keeps its own weights
  only where they beat the worldwide ones by 1% held out, like score_regions.py.

Writes short-range-weights.json and short-range-report.json and prints a report.

  python3 score_short_range.py
"""
import json, os, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

import score_regions as sr

START = date.fromisoformat(os.environ.get("SHORT_START", "2026-04-04"))
END = date.fromisoformat(os.environ.get("SHORT_END", "2026-11-24"))
EVERY = int(os.environ.get("SHORT_EVERY", "6"))     # days between opening times
BANDS = [(0, 2), (3, 5), (6, 11)]
TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "WeatherCore", "blend-regions.json")

# model -> [(cycle hours, hours after the run it's out)], newest-cycle first. The delays are
# Open-Meteo's usual availability, rounded up a little so the scorer never sees a run early.
CYCLES = {
    "gem_seamless": [(6, 4), (12, 5)],              # HRDPS/RDPS 4x a day, GEM global 2x
    "gem_hrdps_continental": [(6, 4)],
    "gfs_seamless": [(6, 5)],
    "gfs_hrrr": [(1, 2), (6, 2)],                   # HRRR runs every hour
    "ncep_nbm_conus": [(1, 2), (6, 2)],
    "ecmwf_ifs025": [(6, 7), (12, 8)],
    "ecmwf_ifs": [(6, 7), (12, 8)],
    "ecmwf_aifs025_single": [(6, 7), (12, 8)],
    "icon_seamless": [(3, 3), (6, 4)],              # ICON-D2/EU every 3 h, global every 6 h
    "ukmo_seamless": [(1, 2), (6, 6)],              # UK 2 km every hour, global every 6 h
    "meteofrance_seamless": [(3, 3), (6, 4)],       # AROME every 3 h
    "knmi_seamless": [(1, 2), (6, 3)],
    "dmi_seamless": [(3, 3), (6, 4)],
    "metno_seamless": [(1, 2), (6, 3)],
}
CORE = ["gem_seamless", "gfs_seamless", "ecmwf_ifs025", "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless"]
NA = ["gem_hrdps_continental", "gfs_hrrr", "ncep_nbm_conus", "ecmwf_ifs"]
EXTRAS = {"europe": ["meteofrance_seamless", "knmi_seamless", "dmi_seamless", "metno_seamless", "ecmwf_ifs"]}
DEFAULT_EXTRAS = ["ecmwf_ifs"]
ALL = CORE + NA + ["meteofrance_seamless", "knmi_seamless", "dmi_seamless", "metno_seamless"]
NAMES = dict(sr.NAMES, metno_seamless="norway")
IDS = {v: k for k, v in NAMES.items()}

STEPS = defaultdict(lambda: defaultdict(int))   # model -> cycle fallback used -> count
sr.ALL = ALL     # score_regions' stats/fit work on sr.ALL


def models_for(reg):
    na = reg in ("na_east", "na_west")
    return CORE + (NA if na else []) + EXTRAS.get(reg, DEFAULT_EXTRAS)


def run_for(model, t, step):
    cycle, delay = CYCLES[model][step]
    out = t - timedelta(hours=delay)
    return out.replace(hour=out.hour - out.hour % cycle, minute=0)


def fetch_runs(icao, lat, lon, models, t):
    """{model: {time: temp}} with each model's newest run out by t (falling back a cycle)."""
    got = {}
    pending = {m: 0 for m in models}
    while pending:
        groups = defaultdict(list)
        for m, step in pending.items():
            groups[run_for(m, t, step)].append(m)
        nxt = {}
        for run, ms in groups.items():
            series = sr.single_run(lat, lon, sorted(ms), run, icao, 2)
            for m in ms:
                s = series.get(m)
                # The run must reach T+11 h; a short or missing run falls back a cycle.
                end = (t + timedelta(hours=11)).strftime("%Y-%m-%dT%H:00")
                if s and end in s:
                    got[m] = s
                    STEPS[m][pending[m]] += 1
                elif pending[m] + 1 < len(CYCLES[m]):
                    nxt[m] = pending[m] + 1
        pending = nxt
    return got


def mae_rows(rows, weights):
    return sr.mae(rows, weights)


def main():
    sr.END = END
    stations = []
    for icao in sr.STATIONS:
        obs, lat, lon = sr.metars(icao)
        if len(obs) < 1500 or lat is None:
            print(f"{icao}: only {len(obs)} hourly reports, skipped", file=sys.stderr, flush=True)
            continue
        stations.append((icao, lat, lon, sr.region_of(lat, lon), obs))
    if os.environ.get("SHORT_STAGE") == "obs":
        return

    times = []
    d, k = START, 0
    while d <= END:
        times.append(datetime(d.year, d.month, d.day, (k * 7) % 24))   # every hour of the day in turn
        d += timedelta(days=EVERY)
        k += 1

    table = json.load(open(TABLE))
    app_now = {r["id"]: r["byDay"][0] for r in table["regions"]}
    app_now["global"] = table["global"]["byDay"][0]

    rows = sr.ROWS          # (icao, band) -> [{model: error}]
    for icao, lat, lon, reg, obs in stations:
        na = reg in ("na_east", "na_west")
        models = models_for(reg)

        def load(t):
            return t, fetch_runs(icao, lat, lon, models, t)

        with ThreadPoolExecutor(3) as pool:
            for t, series in pool.map(load, times):
                for b, (lo, hi) in enumerate(BANDS):
                    for lead in range(lo, hi + 1):
                        vt = (t + timedelta(hours=lead)).strftime("%Y-%m-%dT%H:00")
                        o = obs.get(vt)
                        if o is None:
                            continue
                        e = {m: s[vt] - o for m, s in series.items() if vt in s}
                        # Live, the GFS id is HRRR for the first two days in North America.
                        if na:
                            e.pop("gfs_seamless", None)
                        if len(e) >= 4:
                            rows[(icao, b)].append(e)
        print(f"  {icao}: {sum(len(rows[(icao, b)]) for b in range(len(BANDS)))} scored hours", file=sys.stderr, flush=True)

    by_region = defaultdict(list)
    for s in stations:
        by_region[s[3]].append(s[0])
    all_icaos = [s[0] for s in stations]
    nb = len(BANDS)
    global_w = [sr.fit(sr.pooled_stats(all_icaos, b)) for b in range(nb)]
    global_wo = {(s, b): sr.fit(sr.pooled_stats([x for x in all_icaos if x != s], b))
                 for s in all_icaos for b in range(nb)}

    def as_ids(named):
        return {IDS[k]: v for k, v in named.items() if k in IDS}

    report = {"period": [START.isoformat(), END.isoformat()], "every_days": EVERY, "bands": BANDS,
              "cycles": CYCLES, "regions": {}}
    out = {"bands": BANDS, "regions": {}}
    for rid, name, _ in sr.REGIONS + [("global", "Elsewhere", [])]:
        icaos = by_region.get(rid, [])
        res = {"name": name, "stations": icaos, "bands": []}
        chosen = []
        for b in range(nb):
            r = [e for s in icaos for e in rows[(s, b)]]
            if not r:
                res["bands"].append({"hours": 0})
                chosen.append(global_w[b])
                continue
            st = sr.pooled_stats(icaos, b)
            mem = sr.members_of(st)
            w_all = sr.fit(st, mem)
            now_w = as_ids(app_now.get(rid, app_now["global"]))
            loso = defaultdict(list)
            for s in icaos:
                test = rows[(s, b)]
                if not test:
                    continue
                rest = [x for x in icaos if x != s]
                if len(rest) >= sr.MIN_STATIONS - 1:
                    loso["region"].append((len(test), mae_rows(test, sr.fit(sr.pooled_stats(rest, b)))))
                loso["global"].append((len(test), mae_rows(test, global_wo[(s, b)])))
                loso["app_now"].append((len(test), mae_rows(test, now_w)))
                loso["equal"].append((len(test), mae_rows(test, {m: 1 for m in mem})))
            band = {"hours": len(r), "members": mem,
                    "weights": {NAMES[m]: round(w, 3) for m, w in w_all.items()},
                    "single_mae": {NAMES[m]: round(sum(abs(e[m]) for e in r if m in e) / max(1, sum(m in e for e in r)), 3) for m in mem},
                    "single_bias": {NAMES[m]: round(sum(e[m] for e in r if m in e) / max(1, sum(m in e for e in r)), 3) for m in mem}}
            for k2, v in loso.items():
                band[f"held_out_{k2}"] = round(sum(a * x for a, x in v) / sum(a for a, _ in v), 3)
            won = (rid != "global" and len(icaos) >= sr.MIN_STATIONS and "held_out_region" in band
                   and band["held_out_region"] < band["held_out_global"] * 0.99)
            band["own"] = won
            res["bands"].append(band)
            chosen.append(w_all if won else global_w[b])
        report["regions"][rid] = res
        out["regions"][rid] = [{NAMES[m]: round(w, 3) for m, w in d.items()} for d in chosen]

    # How the chosen weights score held out, next to what the app does now, by region and band.
    for rid, res in report["regions"].items():
        for b, band in enumerate(res["bands"]):
            if not band.get("hours"):
                continue
            pick = "held_out_region" if band.get("own") else "held_out_global"
            band["held_out_chosen"] = band.get(pick)

    report["cycle_used"] = {m: {str(CYCLES[m][k]): n for k, n in v.items()} for m, v in STEPS.items()}
    print("cycle used (cycle h, delay h): count", json.dumps(report["cycle_used"]))
    with open("short-range-weights.json", "w") as f:
        json.dump(out, f, indent=1)
    with open("short-range-report.json", "w") as f:
        json.dump(report, f, indent=1)

    for rid, res in report["regions"].items():
        print(f"\n## {rid} {res['name']} stations={len(res['stations'])}")
        for (lo, hi), band in zip(BANDS, res["bands"]):
            if not band.get("hours"):
                continue
            print(f"  +{lo}-{hi} h hours={band['hours']} own={band['own']} held-out MAE chosen={band.get('held_out_chosen')} "
                  f"app_now={band.get('held_out_app_now')} region={band.get('held_out_region')} "
                  f"global={band.get('held_out_global')} equal={band.get('held_out_equal')}")
            print(f"        weights={band['weights']}")
            print(f"        singles={band['single_mae']} bias={band['single_bias']}")
    print("\nSHORT-RANGE-WEIGHTS-JSON")
    print(json.dumps(out))


if __name__ == "__main__":
    main()
