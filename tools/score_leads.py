#!/usr/bin/env python3
"""Score the blend at the lead times the app really uses, from Open-Meteo's Single Runs archive.

tools/score_models.py works from the Previous Runs API, whose "day 0" is each model's latest
run: for HRRR that's a 1-2 hour forecast, for ECMWF up to ~12 hours. This script instead takes
whole runs (Single Runs API, archived from April 2026) and pretends the app opened at
run + 5 h, when the 00/12 UTC global runs are out; HRRR is taken from the run 2 h before that.
For each lead-time bucket it scores every model, the app's blend (ModelBlend.weight), and a blend
fitted on even days and tested on odd days.

  python3 score_leads.py
"""
import json, math, os, sys, time, urllib.error, urllib.parse, urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402
from score_bias import BY_DAY  # noqa: E402

START = date.fromisoformat(os.environ.get("LEAD_START", "2026-04-05"))
END = date.fromisoformat(os.environ.get("LEAD_END", "2026-10-31"))
GLOBAL = ["gem_seamless", "gem_hrdps_continental", "gfs_seamless", "ecmwf_ifs025",
          "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless"]
HRRR = "gfs_hrrr"
ISSUE_DELAY = 5     # hours after a 00/12 UTC run that the app is opened
HRRR_LAG = 2        # HRRR run used: issue time minus this
BUCKETS = [(0, 3), (3, 6), (6, 12), (12, 18), (18, 24), (24, 36), (36, 48)]


def app_weight(m, lead):
    x = min(max((lead - 12) / 24, 0), len(BY_DAY) - 1)
    i = int(x); j = min(i + 1, len(BY_DAY) - 1); f = x - i
    return BY_DAY[i].get(m, 0) * (1 - f) + BY_DAY[j].get(m, 0) * f


FAILS = defaultdict(int)


def fetch(url, path):
    if os.path.exists(path):
        with open(path) as f:
            d = json.load(f)
        return None if "error" in d else d
    os.makedirs(sm.CACHE, exist_ok=True)
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
            with open(path, "w") as f:
                json.dump(d, f)
            time.sleep(0.3)
            return d
        except urllib.error.HTTPError as e:
            if e.code == 400:
                body = e.read().decode()[:200]
                FAILS[body] += 1
                if FAILS[body] <= 3:
                    print("  400", body, url[-160:], file=sys.stderr)
                with open(path, "w") as f:
                    json.dump({"error": body}, f)
                return None
            time.sleep(20 * (attempt + 1))
        except Exception:
            time.sleep(10 * (attempt + 1))
    return None


def run_series(lat, lon, models, run, tag):
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": "temperature_2m",
         "models": ",".join(models), "run": run.strftime("%Y-%m-%dT%H:%M"), "timezone": "GMT",
         "forecast_days": 3}
    url = "https://single-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
    d = fetch(url, os.path.join(sm.CACHE, f"run-{tag}-{run:%Y%m%d%H}-{'_'.join(models)}.json"))
    if d is None:
        if len(models) > 1:   # one model's run missing fails the whole call: ask one by one
            out = {}
            for m in models:
                out.update(run_series(lat, lon, [m], run, tag))
            return out
        return {}
    h = d.get("hourly", {})
    times = h.get("time", [])
    out = {}
    for m in models:
        key = f"temperature_2m_{m}" if len(models) > 1 else "temperature_2m"
        vals = h.get(key) or []
        out[m] = {t: v for t, v in zip(times, vals) if v is not None}
    return out


def main():
    from concurrent.futures import ThreadPoolExecutor
    rows = []   # (bucket, lead, {model: err}, day parity, station)
    for cid, label in sm.STATIONS:
        lat, lon = sm.station_coords(cid)
        sm.START, sm.END = START, END
        ot, _ = sm.observations(cid)
        print(label, len(ot), "obs", file=sys.stderr, flush=True)
        runs = []
        d = START
        while d <= END:
            for hh in (0, 12):
                runs.append((d, datetime(d.year, d.month, d.day, hh)))
            d += timedelta(days=1)

        def load(item):
            day, run = item
            issue = run + timedelta(hours=ISSUE_DELAY)
            series = run_series(lat, lon, GLOBAL, run, cid)
            series.update(run_series(lat, lon, [HRRR], issue - timedelta(hours=HRRR_LAG), cid))
            return day, issue, series

        with ThreadPoolExecutor(6) as pool:
            for k, (day, issue, series) in enumerate(pool.map(load, runs)):
                if k % 50 == 0:
                    print(f"  {label} run {k}/{len(runs)}", file=sys.stderr, flush=True)
                for lead in range(48):
                    t = (issue + timedelta(hours=lead)).strftime("%Y-%m-%dT%H:00")
                    o = ot.get(t)
                    if o is None:
                        continue
                    e = {m: s[t] - o for m, s in series.items() if t in s}
                    if len(e) < 5:
                        continue
                    b = next(i for i, (a, z) in enumerate(BUCKETS) if a <= lead < z)
                    rows.append((b, lead, e, day.toordinal() % 2, label))
        print(" ", label, "rows", len(rows), file=sys.stderr, flush=True)

    models = GLOBAL + [HRRR]
    report = {}
    for b, (a, z) in enumerate(BUCKETS):
        sub = [r for r in rows if r[0] == b]
        if not sub:
            continue
        mem = [m for m in models if sum(1 for r in sub if m in r[2]) >= 0.9 * len(sub)]
        full = [r for r in sub if all(m in r[2] for m in mem)]
        res = {"hours": len(full)}
        for m in mem:
            res[sm.NAMES.get(m, m)] = round(sum(abs(r[2][m]) for r in full) / len(full), 3)
            res[sm.NAMES.get(m, m) + "_bias"] = round(sum(r[2][m] for r in full) / len(full), 3)
        def app(r):
            ws = {m: app_weight(m, r[1]) for m in mem}
            s = sum(ws.values())
            return sum(r[2][m] * w for m, w in ws.items()) / s if s else None
        res["AppBlend"] = round(sum(abs(app(r)) for r in full) / len(full), 3)
        res["AppBlend_bias"] = round(sum(app(r) for r in full) / len(full), 3)
        # Same weights, but each day's row centred 9 h earlier (lead 3, 27, 51 ... instead of
        # 12, 36, 60): the previous-runs "day N" is closer to lead 24N + a few hours.
        def shifted(r):
            ws = {m: app_weight(m, r[1] + 9) for m in mem}
            s = sum(ws.values())
            return sum(r[2][m] * w for m, w in ws.items()) / s if s else None
        res["AppShifted"] = round(sum(abs(shifted(r)) for r in full) / len(full), 3)
        def cov(s):
            k = len(mem); C = [[0.0] * k for _ in range(k)]
            for r in s:
                for i in range(k):
                    for j in range(k):
                        C[i][j] += r[2][mem[i]] * r[2][mem[j]]
            return [[x / max(len(s), 1) for x in row] for row in C]
        train = [r for r in full if r[3] == 0]; test = [r for r in full if r[3] == 1]
        w = sm.simplex_min(cov(train))
        res["fitted_test"] = round(sum(abs(sum(w[i] * r[2][mem[i]] for i in range(len(mem)))) for r in test) / len(test), 3)
        res["app_test"] = round(sum(abs(app(r)) for r in test) / len(test), 3)
        wall = sm.simplex_min(cov(full))
        res["weights"] = {sm.NAMES.get(m, m): round(x, 3) for m, x in zip(mem, wall)}
        report[f"{a}-{z}h"] = res
    with open("lead-results.json", "w") as f:
        json.dump(report, f, indent=1)
    for k, r in report.items():
        print(f"{k:>7} hours={r['hours']} app={r['AppBlend']} shifted={r['AppShifted']} "
              f"fitted_test={r['fitted_test']} app_test={r['app_test']} weights={r['weights']}")
        print("        " + " ".join(f"{m}={v}" for m, v in r.items() if isinstance(v, float) and not m.endswith('_bias')
                                     and m not in ('AppBlend', 'AppShifted', 'fitted_test', 'app_test')))


if __name__ == "__main__":
    main()
