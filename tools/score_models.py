#!/usr/bin/env python3
"""Score Open-Meteo models against ECCC station observations near Milton, Ontario.

Pure standard library. Downloads into ./verify-cache (re-runs reuse it), prints a
report and writes verify-results.json.

  python3 score_models.py            # Nov 2025 - Oct 2026
"""
import json, math, os, sys, time, urllib.parse, urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone, date

START, END = date(2025, 11, 1), date(2026, 10, 31)
MODELS = ["gem_hrdps_continental", "gfs_hrrr", "gem_seamless", "ecmwf_ifs025",
          "icon_seamless", "ukmo_seamless", "gfs_seamless", "best_match"]
# Extra candidates to score alongside, e.g. EXTRA=gem_regional,ecmwf_aifs025_single
EXTRA = [m for m in os.environ.get("EXTRA", "").split(",") if m]
BLEND = MODELS[:7] + EXTRA
MODELS = MODELS + EXTRA
NAMES = {"gem_hrdps_continental": "HRDPS", "gfs_hrrr": "HRRR", "gem_seamless": "GEM",
         "ecmwf_ifs025": "ECMWF", "icon_seamless": "ICON", "ukmo_seamless": "UKMO",
         "gfs_seamless": "GFS", "best_match": "BestMatch", "blend_now": "AppBlend"}
for _m in EXTRA:
    NAMES.setdefault(_m, _m)
LEADS = [0, 1, 2, 3, 4, 5]          # previous_dayN
# Candidate stations (climate id, label). Hourly + daily share the id at these.
STATIONS = [("6158731", "Toronto Pearson"), ("6153193", "Hamilton Airport")]
WET_MM = 0.5
CACHE = "verify-cache"
LST = timezone(timedelta(hours=-5))   # ECCC climate days are local standard time

# App's current weights (ModelBlend.swift)
SHORT = {"gem_hrdps_continental": 3, "gfs_hrrr": 2.5, "gem_seamless": 1.5, "ecmwf_ifs025": 1.5,
         "icon_seamless": 1, "ukmo_seamless": 1, "gfs_seamless": 0.5}
LONG = {"ecmwf_ifs025": 3, "gem_seamless": 2, "icon_seamless": 1.5, "ukmo_seamless": 1.5,
        "gfs_seamless": 1, "gem_hrdps_continental": 1, "gfs_hrrr": 1}

def app_weight(m, lead_h):
    f = min(max((lead_h - 36) / 24, 0), 1)
    return SHORT.get(m, 0) * (1 - f) + LONG.get(m, 0) * f

def get_json(url, name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = json.load(r)
            with open(path, "w") as f:
                json.dump(data, f)
            time.sleep(1)
            return data
        except Exception as e:
            print("  retry", attempt, name, e, file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    raise RuntimeError("failed " + url)

def ogc_all(collection, params, tag):
    feats, offset = [], 0
    while True:
        q = dict(params, f="json", limit=10000, offset=offset)
        url = f"https://api.weather.gc.ca/collections/{collection}/items?" + urllib.parse.urlencode(q)
        d = get_json(url, f"{tag}-{offset}.json")
        batch = d.get("features", [])
        feats += batch
        if len(batch) < 10000:
            return feats
        offset += 10000

def parse_time(s):
    s = s.replace("Z", "")
    return datetime.fromisoformat(s[:19])

# ---------- observations ----------
def observations(cid):
    rng = f"{START.isoformat()}T00:00:00/{(END + timedelta(days=1)).isoformat()}T06:00:00"
    hourly = ogc_all("climate-hourly", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"hly-{cid}")
    daily = ogc_all("climate-daily", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"dly-{cid}")
    obs_t = {}
    for f in hourly:
        p = f["properties"]
        t = p.get("TEMP")
        if t is None:
            continue
        if p.get("UTC_DATE"):
            ut = parse_time(p["UTC_DATE"])
        else:  # LOCAL_DATE is local standard time
            ut = parse_time(p["LOCAL_DATE"]) + timedelta(hours=5)
        obs_t[ut.strftime("%Y-%m-%dT%H:00")] = float(t)
    obs_p = {}
    for f in daily:
        p = f["properties"]
        v = p.get("TOTAL_PRECIPITATION")
        if v is not None:
            obs_p[parse_time(p["LOCAL_DATE"]).date().isoformat()] = float(v)
    if hourly:
        print(f"  hourly keys: {sorted(hourly[0]['properties'].keys())[:40]}")
    return obs_t, obs_p

def station_coords(cid):
    d = get_json("https://api.weather.gc.ca/collections/climate-stations/items?" +
                 urllib.parse.urlencode({"CLIMATE_IDENTIFIER": cid, "f": "json"}), f"stn-{cid}.json")
    lon, lat = d["features"][0]["geometry"]["coordinates"][:2]
    return lat, lon

# ---------- forecasts ----------
def months():
    d = START
    while d <= END:
        nxt = (d.replace(day=28) + timedelta(days=4)).replace(day=1)
        yield d, min(nxt - timedelta(days=1), END)
        d = nxt

def forecasts(lat, lon, cid):
    """{model: {lead: {utc hour: (temp, precip)}}}"""
    out = defaultdict(lambda: defaultdict(dict))
    vars_ = []
    for base in ("temperature_2m", "precipitation"):
        vars_.append(base)
        vars_ += [f"{base}_previous_day{n}" for n in LEADS[1:]]
    for a, b in months():
        q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
             "models": ",".join(MODELS), "timezone": "GMT",
             "start_date": a.isoformat(), "end_date": (b + timedelta(days=1)).isoformat()}
        url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
        d = get_json(url, f"fc-{cid}-{a.isoformat()}.json" if not EXTRA
                     else f"fc-{cid}-{a.isoformat()}-{'_'.join(EXTRA)}.json")
        h = d["hourly"]
        times = h["time"]
        for m in MODELS:
            for n in LEADS:
                suf = "" if n == 0 else f"_previous_day{n}"
                ts = h.get(f"temperature_2m{suf}_{m}") or [None] * len(times)
                ps = h.get(f"precipitation{suf}_{m}") or [None] * len(times)
                for i, t in enumerate(times):
                    if ts[i] is not None or ps[i] is not None:
                        out[m][n][t] = (ts[i], ps[i])
        print(f"  {cid} {a:%Y-%m} ok", file=sys.stderr)
    return out

def season(d):
    return {12: "Winter", 1: "Winter", 2: "Winter", 3: "Spring", 4: "Spring", 5: "Spring",
            6: "Summer", 7: "Summer", 8: "Summer"}.get(d.month, "Fall")

def lst_day(utc_str):
    return (datetime.fromisoformat(utc_str).replace(tzinfo=timezone.utc).astimezone(LST)).date()

class Acc:
    def __init__(s): s.n = 0; s.ae = 0.0; s.se = 0.0; s.b = 0.0
    def add(s, e): s.n += 1; s.ae += abs(e); s.se += e * e; s.b += e
    def res(s):
        return None if s.n == 0 else {"n": s.n, "mae": round(s.ae / s.n, 3),
                                       "rmse": round(math.sqrt(s.se / s.n), 3), "bias": round(s.b / s.n, 3)}

def simplex_min(C, iters=4000):
    """Minimise w'Cw over the simplex (exponentiated gradient)."""
    k = len(C)
    w = [1.0 / k] * k
    scale = max(C[i][i] for i in range(k)) or 1
    eta = 0.5 / scale
    for _ in range(iters):
        g = [2 * sum(C[i][j] * w[j] for j in range(k)) for i in range(k)]
        w = [w[i] * math.exp(-eta * g[i]) for i in range(k)]
        s = sum(w); w = [x / s for x in w]
    return w

def main():
    data = []
    for cid, label in STATIONS:
        print("Station", cid, label, file=sys.stderr)
        lat, lon = station_coords(cid)
        ot, op = observations(cid)
        print(f"  {label}: {len(ot)} hourly temps, {len(op)} daily precip; at {lat},{lon}", file=sys.stderr)
        if len(ot) < 500:
            print("  WARNING few observations, skipping", file=sys.stderr); continue
        data.append((label, ot, op, forecasts(lat, lon, cid)))

    hourly = defaultdict(Acc)        # (model, lead, season) and (model, lead, "All")
    hi, lo = defaultdict(Acc), defaultdict(Acc)
    pc = defaultdict(lambda: [0, 0, 0, 0])   # hit, miss, false alarm, correct no
    errs = defaultdict(list)          # lead -> list of ({model: err}, dayparity)
    for label, ot, op, fc in data:
        models = list(fc.keys()) + ["blend_now"]
        for n in LEADS:
            dmax, dmin, dobs = defaultdict(dict), defaultdict(dict), defaultdict(list)
            dpre = defaultdict(lambda: defaultdict(float)); dcnt = defaultdict(lambda: defaultdict(int))
            for t, o in ot.items():
                day = lst_day(t)
                if not (START <= day <= END):
                    continue
                dobs[day].append(o)
                row = {}
                for m in fc:
                    v = fc[m][n].get(t)
                    if v and v[0] is not None:
                        row[m] = v[0]
                lead_h = 24 * n + 12
                ws = {m: app_weight(m, lead_h) for m in row if m in BLEND}
                if sum(ws.values()) > 0:
                    row["blend_now"] = sum(row[m] * w for m, w in ws.items()) / sum(ws.values())
                for m, v in row.items():
                    e = v - o
                    hourly[(m, n, season(day))].add(e); hourly[(m, n, "All")].add(e)
                    dmax[day].setdefault(m, []).append(v)
                errs[n].append(({m: row[m] - o for m in row if m in BLEND}, day.toordinal() % 2))
            for day, obs in dobs.items():
                if len(obs) < 20:
                    continue
                for m, vals in dmax[day].items():
                    if len(vals) < 20:
                        continue
                    for k in ("All", season(day)):
                        hi[(m, n, k)].add(max(vals) - max(obs)); lo[(m, n, k)].add(min(vals) - min(obs))
            # precip by LST day
            for m in fc:
                for t, (tv, pv) in fc[m][n].items():
                    if pv is None:
                        continue
                    day = lst_day(t)
                    dpre[m][day] += pv; dcnt[m][day] += 1
                for day, tot in dpre[m].items():
                    if dcnt[m][day] < 24 or day.isoformat() not in op or not (START <= day <= END):
                        continue
                    f, o = tot >= WET_MM, op[day.isoformat()] >= WET_MM
                    for k in ("All", season(day)):
                        c = pc[(m, n, k)]
                        c[0 if f and o else 1 if o else 2 if f else 3] += 1

    # weights per lead
    weights = {}
    for n in LEADS:
        rows = errs[n]
        cover = defaultdict(int)
        for r, _ in rows:
            for m in r: cover[m] += 1
        mem = [m for m in BLEND if cover[m] >= 0.6 * len(rows)]
        full = [(r, p) for r, p in rows if all(m in r for m in mem)]
        def cov(sub):
            k = len(mem); C = [[0.0] * k for _ in range(k)]
            for r, _ in sub:
                for i in range(k):
                    for j in range(k):
                        C[i][j] += r[mem[i]] * r[mem[j]]
            return [[x / max(len(sub), 1) for x in row] for row in C]
        def mae(sub, w):
            return sum(abs(sum(w[i] * r[mem[i]] for i in range(len(mem)))) for r, _ in sub) / max(len(sub), 1)
        train = [x for x in full if x[1] == 0]; test = [x for x in full if x[1] == 1]
        wt = simplex_min(cov(train))
        cur = [app_weight(m, 24 * n + 12) for m in mem]; s = sum(cur); cur = [c / s for c in cur]
        eq = [1 / len(mem)] * len(mem)
        singles = {NAMES[m]: round(mae(test, [1 if j == i else 0 for j in range(len(mem))]), 3) for i, m in enumerate(mem)}
        wall = simplex_min(cov(full))
        weights[n] = {"members": [NAMES[m] for m in mem], "hours": len(full),
                      "test_mae": {"fitted": round(mae(test, wt), 3), "app_now": round(mae(test, cur), 3),
                                   "equal": round(mae(test, eq), 3), **singles},
                      "fitted_weights_all": {NAMES[m]: round(w, 3) for m, w in zip(mem, wall)}}

    res = {"stations": [d[0] for d in data], "period": [START.isoformat(), END.isoformat()],
           "hourly_temp": {f"{NAMES.get(m,m)}|{n}|{k}": a.res() for (m, n, k), a in hourly.items()},
           "daily_high": {f"{NAMES.get(m,m)}|{n}|{k}": a.res() for (m, n, k), a in hi.items()},
           "daily_low": {f"{NAMES.get(m,m)}|{n}|{k}": a.res() for (m, n, k), a in lo.items()},
           "precip": {}, "weights": weights}
    for (m, n, k), (h, mi, fa, cn) in pc.items():
        tot = h + mi + fa + cn
        res["precip"][f"{NAMES.get(m,m)}|{n}|{k}"] = {
            "n": tot, "accuracy": round((h + cn) / tot, 3) if tot else None,
            "hit_rate": round(h / (h + mi), 3) if h + mi else None,
            "false_alarm": round(fa / (h + fa), 3) if h + fa else None,
            "csi": round(h / (h + mi + fa), 3) if h + mi + fa else None}
    with open("verify-results.json", "w") as f:
        json.dump(res, f, indent=1)

    def table(title, d, key):
        print(f"\n## {title}")
        names = [NAMES[m] for m in MODELS] + ["AppBlend"]
        print("lead  " + " ".join(f"{x:>9}" for x in names))
        for n in LEADS:
            cells = []
            for x in names:
                r = d.get(f"{x}|{n}|All")
                cells.append(f"{r[key]:>9}" if r and r.get(key) is not None else f"{'-':>9}")
            print(f"day{n}  " + " ".join(cells))
    table("Hourly temperature MAE (C)", res["hourly_temp"], "mae")
    table("Hourly temperature bias (C)", res["hourly_temp"], "bias")
    table("Daily high MAE (C)", res["daily_high"], "mae")
    table("Daily low MAE (C)", res["daily_low"], "mae")
    table("Wet day (>=0.5 mm) accuracy", res["precip"], "accuracy")
    table("Wet day CSI", res["precip"], "csi")
    for k in ("Winter", "Spring", "Summer", "Fall"):
        print(f"\n## {k} hourly temp MAE, day1 / day3")
        for x in [NAMES[m] for m in MODELS] + ["AppBlend"]:
            a = res["hourly_temp"].get(f"{x}|1|{k}"); b = res["hourly_temp"].get(f"{x}|3|{k}")
            print(f"  {x:>10} {a['mae'] if a else '-':>7} {b['mae'] if b else '-':>7}")
    print("\n## Weights per lead day")
    print(json.dumps(weights, indent=1))

if __name__ == "__main__":
    main()
