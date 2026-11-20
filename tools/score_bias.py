#!/usr/bin/env python3
"""Does a bias correction make the app's blend more accurate, and does it carry to a new place?

Builds the app's blend (ModelBlend.byDay) from 12 months of archived Open-Meteo forecasts at
several ECCC stations around Milton, then fits a correction on part of the data and scores it
on the rest:
  - "split":   fit on even days, test on odd days (all stations)
  - "station": fit on every other station, test on the one left out (does it travel?)
Also compares daily wet/dry calls from Open-Meteo's best match with a model consensus.

  EXTRA=ecmwf_aifs025_single python3 score_bias.py
"""
import json, math, os, sys, urllib.parse
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo

os.environ.setdefault("EXTRA", "ecmwf_aifs025_single")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402

TZ = ZoneInfo("America/Toronto")
MILTON = (43.5183, -79.8774)

# ModelBlend.byDay, keyed by Open-Meteo model id.
BY_DAY = [
    {"gfs_hrrr": 0.45, "gfs_seamless": 0.32, "icon_seamless": 0.12, "ukmo_seamless": 0.08, "ecmwf_ifs025": 0.03},
    {"ecmwf_aifs025_single": 0.28, "icon_seamless": 0.22, "ukmo_seamless": 0.185, "gem_hrdps_continental": 0.12,
     "gem_seamless": 0.10, "ecmwf_ifs025": 0.04, "gfs_hrrr": 0.025, "gfs_seamless": 0.025},
    {"ecmwf_aifs025_single": 0.35, "gfs_seamless": 0.23, "icon_seamless": 0.18, "ukmo_seamless": 0.125,
     "ecmwf_ifs025": 0.075, "gem_seamless": 0.04},
    {"ecmwf_aifs025_single": 0.43, "gfs_seamless": 0.235, "ukmo_seamless": 0.11, "icon_seamless": 0.095,
     "ecmwf_ifs025": 0.085, "gem_seamless": 0.045},
    {"ecmwf_aifs025_single": 0.47, "gfs_seamless": 0.23, "ukmo_seamless": 0.125, "ecmwf_ifs025": 0.075,
     "icon_seamless": 0.07, "gem_seamless": 0.03},
    {"ecmwf_aifs025_single": 0.49, "ecmwf_ifs025": 0.165, "gfs_seamless": 0.15, "ukmo_seamless": 0.08,
     "icon_seamless": 0.06, "gem_seamless": 0.055},
]
CONSENSUS = ["gem_seamless", "gfs_seamless", "ecmwf_ifs025", "icon_seamless", "ukmo_seamless",
             "ecmwf_aifs025_single", "gem_hrdps_continental"]


def km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (*a, *b))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 12742 * math.asin(math.sqrt(h))


def discover():
    """ECCC climate stations within ~70 km of Milton that report hourly data through the period."""
    q = {"f": "json", "bbox": "-80.75,43.0,-79.0,44.1", "limit": 500}
    d = sm.get_json("https://api.weather.gc.ca/collections/climate-stations/items?" + urllib.parse.urlencode(q),
                    "stations-bbox.json")
    out = []
    feats = d.get("features", [])
    if feats:
        print("station fields:", sorted(feats[0]["properties"].keys()), file=sys.stderr)
    for f in feats:
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"][:2]
        last = str(p.get("HLY_LAST_DATE") or "")[:10]
        first = str(p.get("HLY_FIRST_DATE") or "")[:10]
        if not last or last < "2026-10-15" or not first or first > "2025-11-01":
            continue
        out.append((p["CLIMATE_IDENTIFIER"], p.get("STATION_NAME"), lat, lon, round(km(MILTON, (lat, lon)), 1)))
    out.sort(key=lambda x: x[4])
    print("Hourly stations near Milton:", file=sys.stderr)
    for s in out:
        print("  ", s, file=sys.stderr)
    return out


class Acc:
    def __init__(s): s.n = 0; s.ae = 0.0; s.b = 0.0
    def add(s, e): s.n += 1; s.ae += abs(e); s.b += e
    def mae(s): return round(s.ae / s.n, 3) if s.n else None
    def bias(s): return round(s.b / s.n, 3) if s.n else None


def blend_rows(fc, ot):
    """[(station-independent key fields), error] for every hour with an observation."""
    rows = []
    for t, o in ot.items():
        ut = datetime.fromisoformat(t).replace(tzinfo=timezone.utc)
        lt = ut.astimezone(TZ)
        if not (sm.START <= lt.date() <= sm.END):
            continue
        for n, w in enumerate(BY_DAY):
            s = tot = 0.0
            for m, wm in w.items():
                v = fc.get(m, {}).get(n, {}).get(t)
                if v and v[0] is not None:
                    s += v[0] * wm; tot += wm
            if tot < 0.75:
                continue
            rows.append({"n": n, "hour": lt.hour, "month": lt.month, "day": lt.date(),
                         "season": sm.season(lt.date()), "fc": s / tot, "obs": o})
    return rows


def fit(rows, key, shrink=30):
    """Mean error per group, shrunk toward the lead's overall mean for small groups."""
    by_n, by_g = defaultdict(list), defaultdict(list)
    for r in rows:
        e = r["fc"] - r["obs"]
        by_n[r["n"]].append(e); by_g[key(r)].append(e)
    base = {n: sum(v) / len(v) for n, v in by_n.items()}
    out = {}
    for g, v in by_g.items():
        n = g[0]
        out[g] = (sum(v) + base[n] * shrink) / (len(v) + shrink)
    return out, base


VARIANTS = {
    "lead": lambda r: (r["n"],),
    "lead+hour": lambda r: (r["n"], r["hour"]),
    "lead+hour+season": lambda r: (r["n"], r["hour"], r["season"]),
    "lead+hour+month": lambda r: (r["n"], r["hour"], r["month"]),
}


def score(rows, corr=None, key=None, factor=1.0):
    hourly = defaultdict(Acc)
    days = defaultdict(lambda: ([], []))
    for r in rows:
        c = corr.get(key(r), 0) * factor if corr else 0
        f = r["fc"] - c
        hourly[r["n"]].add(f - r["obs"])
        d = days[(r.get("stn"), r["n"], r["day"])]
        d[0].append(f); d[1].append(r["obs"])
    hi, lo = defaultdict(Acc), defaultdict(Acc)
    for (_, n, _), (f, o) in days.items():
        if len(o) >= 20:
            hi[n].add(max(f) - max(o)); lo[n].add(min(f) - min(o))
    return {n: {"mae": hourly[n].mae(), "bias": hourly[n].bias(), "high": hi[n].mae(), "low": lo[n].mae(),
                "high_bias": hi[n].bias(), "low_bias": lo[n].bias()} for n in sorted(hourly)}


def precip_rows(fc, op):
    """Daily (local standard time) totals per model and lead, against the station's daily total."""
    out = []
    for n in sm.LEADS:
        tot, cnt = defaultdict(lambda: defaultdict(float)), defaultdict(lambda: defaultdict(int))
        for m in CONSENSUS + ["best_match"]:
            for t, (_, p) in fc.get(m, {}).get(n, {}).items():
                if p is None:
                    continue
                d = sm.lst_day(t)
                tot[d][m] += p; cnt[d][m] += 1
        for d, ms in tot.items():
            if d.isoformat() not in op or not (sm.START <= d <= sm.END):
                continue
            full = {m: v for m, v in ms.items() if cnt[d][m] >= 24}
            if "best_match" not in full or sum(1 for m in CONSENSUS if m in full) < 4:
                continue
            out.append({"n": n, "obs": op[d.isoformat()], "models": full})
    return out


def precip_scores(rows):
    res = {}
    for n in sm.LEADS:
        sub = [r for r in rows if r["n"] == n]
        if not sub:
            continue
        cand = {}
        def cat(pred):
            h = mi = fa = cn = 0
            for r in sub:
                f, o = pred(r), r["obs"] >= sm.WET_MM
                if f and o: h += 1
                elif o: mi += 1
                elif f: fa += 1
                else: cn += 1
            return {"acc": round((h + cn) / len(sub), 3), "csi": round(h / max(h + mi + fa, 1), 3),
                    "pod": round(h / max(h + mi, 1), 3), "far": round(fa / max(h + fa, 1), 3)}
        def frac(r):
            v = [r["models"][m] >= sm.WET_MM for m in CONSENSUS if m in r["models"]]
            return sum(v) / len(v)
        def median(r):
            v = sorted(r["models"][m] for m in CONSENSUS if m in r["models"])
            return v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2
        cand["best_match"] = cat(lambda r: r["models"]["best_match"] >= sm.WET_MM)
        for k in (0.3, 0.4, 0.5, 0.6):
            cand[f"consensus>={k}"] = cat(lambda r, k=k: frac(r) >= k)
        cand["median_mm"] = cat(lambda r: median(r) >= sm.WET_MM)
        # Brier: model-consensus fraction as a probability vs best match's 0/1
        cand["brier_consensus"] = round(sum((frac(r) - (r["obs"] >= sm.WET_MM)) ** 2 for r in sub) / len(sub), 4)
        cand["brier_best_match"] = round(sum(((r["models"]["best_match"] >= sm.WET_MM) - (r["obs"] >= sm.WET_MM)) ** 2
                                             for r in sub) / len(sub), 4)
        cand["days"] = len(sub)
        res[n] = cand
    return res


def main():
    found = discover()
    wanted = os.environ.get("STATIONS")
    stations = [s for s in found if not wanted or s[0] in wanted.split(",")][: int(os.environ.get("MAX_STATIONS", 5))]
    if not stations:
        stations = [(cid, label, *sm.station_coords(cid), None) for cid, label in sm.STATIONS]
    all_rows, prows, used = [], [], []
    for cid, label, lat, lon, dist in stations:
        print("Station", cid, label, dist, "km", file=sys.stderr)
        try:
            ot, op = sm.observations(cid)
        except Exception as e:
            print("  obs failed", e, file=sys.stderr); continue
        if len(ot) < 4000:
            print(f"  only {len(ot)} hourly temps, skipping", file=sys.stderr); continue
        fc = sm.forecasts(lat, lon, cid)
        rows = blend_rows(fc, ot)
        for r in rows:
            r["stn"] = label
        all_rows += rows
        prows += precip_rows(fc, op)
        used.append({"id": cid, "name": label, "km_from_milton": dist, "hours": len(ot)})

    report = {"stations": used, "uncorrected": score(all_rows)}
    # 1) even/odd day split
    train = [r for r in all_rows if r["day"].toordinal() % 2 == 0]
    test = [r for r in all_rows if r["day"].toordinal() % 2 == 1]
    report["split"] = {"uncorrected": score(test)}
    for name, key in VARIANTS.items():
        corr, _ = fit(train, key)
        report["split"][name] = score(test, corr, key)
        report["split"][name + " x0.7"] = score(test, corr, key, 0.7)
    # 2) leave one station out
    report["station"] = {}
    for s in used:
        name = s["name"]
        tr = [r for r in all_rows if r["stn"] != name]
        te = [r for r in all_rows if r["stn"] == name]
        if not tr or not te:
            continue
        out = {"uncorrected": score(te)}
        for v in ("lead+hour", "lead+hour+season", "lead+hour+month"):
            corr, _ = fit(tr, VARIANTS[v])
            out[v] = score(te, corr, VARIANTS[v])
            out[v + " x0.7"] = score(te, corr, VARIANTS[v], 0.7)
        report["station"][name] = out
    # Per-station raw bias by lead, to see whether stations agree
    report["station_bias"] = {s["name"]: score([r for r in all_rows if r["stn"] == s["name"]]) for s in used}
    # 3) The tables to ship: fitted on everything
    tables = {}
    for v in ("lead+hour", "lead+hour+season", "lead+hour+month"):
        corr, base = fit(all_rows, VARIANTS[v])
        tables[v] = {"|".join(map(str, k)): round(c, 2) for k, c in sorted(corr.items())}
    report["tables"] = tables
    report["precip"] = precip_scores(prows)

    with open("bias-results.json", "w") as f:
        json.dump(report, f, indent=1, default=str)

    def line(label, s):
        cells = " ".join(f"d{n}:{v['mae']:.2f}/{v['high']:.2f}/{v['low']:.2f}" for n, v in s.items()
                         if v["mae"] is not None and v["high"] is not None)
        print(f"  {label:<26} {cells}")
    print("Stations:", json.dumps(used))
    print("\nHourly MAE / high MAE / low MAE by lead day\n## even/odd split")
    for k, v in report["split"].items():
        line(k, v)
    for name, out in report["station"].items():
        print(f"## held-out station: {name}")
        for k, v in out.items():
            line(k, v)
    print("\n## raw blend bias by station (hourly / high / low)")
    for name, s in report["station_bias"].items():
        print(f"  {name:<26} " + " ".join(f"d{n}:{v['bias']:+.2f}/{(v['high_bias'] or 0):+.2f}/{(v['low_bias'] or 0):+.2f}"
                                           for n, v in s.items()))
    print("\n## lead+hour table (blend minus observed, °C), rows = lead day, cols = local hour 0..23")
    t = tables["lead+hour"]
    for n in range(6):
        print(f"  d{n} " + " ".join(f"{t.get(f'{n}|{h}', 0):+.1f}" for h in range(24)))
    print("\n## lead+hour+season table")
    t = tables["lead+hour+season"]
    for s in ("Winter", "Spring", "Summer", "Fall"):
        for n in range(6):
            print(f"  {s[:2]} d{n} " + " ".join(f"{t.get(f'{n}|{h}|{s}', 0):+.1f}" for h in range(24)))
    print("\n## precipitation (daily wet >= 0.5 mm)")
    print(json.dumps(report["precip"], indent=1))


if __name__ == "__main__":
    main()
