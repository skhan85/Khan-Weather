#!/usr/bin/env python3
"""Score the forward log (forecast-log branch: live Open-Meteo forecasts for Milton saved every
few hours since 15 Nov 2026) at true lead times against ECCC hourly readings near Milton.

Checks the app's blend against each model and against the weights fitted on April-October single
runs (tools/score_leads.py), to see whether that summer fit holds in November.

  python3 score_forward.py forecast-log.jsonl
"""
import json, os, sys, urllib.parse
from collections import defaultdict
from datetime import datetime, timezone, timedelta, date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402
from score_leads import app_weight  # noqa: E402

STATIONS = [("6158731", "Pearson"), ("6153193", "Hamilton A"), ("6153301", "Hamilton RBG"),
            ("6143092", "Guelph"), ("6151061", "Burlington Piers")]
BUCKETS = [(0, 6), (6, 12), (12, 24), (24, 48), (48, 96)]
# score_leads.py fit (Apr-Oct 2026, held out), by bucket start
SUMMER = {0: {"icon_seamless": .35, "gfs_hrrr": .24, "ecmwf_ifs025": .17, "ukmo_seamless": .12, "gem_seamless": .12},
          6: {"icon_seamless": .37, "gfs_hrrr": .12, "ecmwf_ifs025": .16, "ukmo_seamless": .11, "gem_seamless": .19, "gfs_seamless": .06},
          12: {"icon_seamless": .37, "gfs_seamless": .19, "ecmwf_ifs025": .16, "ukmo_seamless": .10, "gem_seamless": .17, "ecmwf_aifs025_single": .04},
          24: {"icon_seamless": .32, "gfs_seamless": .19, "ecmwf_ifs025": .12, "ukmo_seamless": .10, "gem_seamless": .14, "ecmwf_aifs025_single": .14},
          48: {"icon_seamless": .32, "gfs_seamless": .19, "ecmwf_ifs025": .12, "ukmo_seamless": .10, "gem_seamless": .14, "ecmwf_aifs025_single": .14}}


def obs(cid, start, end):
    rng = f"{start}T00:00:00/{end}T23:00:00"
    url = ("https://api.weather.gc.ca/collections/climate-hourly/items?" +
           urllib.parse.urlencode({"CLIMATE_IDENTIFIER": cid, "datetime": rng, "f": "json", "limit": 10000}))
    d = sm.get_json(url, f"fwd-{cid}-{start}-{end}.json")
    out = {}
    for f in d.get("features", []):
        p = f["properties"]
        if p.get("TEMP") is not None and p.get("UTC_DATE"):
            out[int(sm.parse_time(p["UTC_DATE"]).replace(tzinfo=timezone.utc).timestamp())] = float(p["TEMP"])
    return out


def wavg(vals, w):
    s = sum(w.get(m, 0) for m in vals)
    return sum(v * w.get(m, 0) for m, v in vals.items()) / s if s else None


NAMES = {"gem_seamless": "canada", "gem_hrdps_continental": "canadaHighRes", "gfs_seamless": "us",
         "gfs_hrrr": "usHighRes", "ecmwf_ifs025": "europe", "ecmwf_aifs025_single": "europeAI",
         "icon_seamless": "germany", "ukmo_seamless": "uk"}
_REG = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "WeatherCore",
                                   "blend-regions.json")))
NA_EAST = next(r for r in _REG["regions"] if r["id"] == "na_east")["byDay"]


def region_weight(m, lead):
    """Today's app weight (blend-regions.json, Eastern North America) for a logged model; models
    the log lacks (NBM, ECMWF 9 km) drop out and the rest are renormalised by wavg."""
    row = NA_EAST[min(int(max(lead, 0) // 24), len(NA_EAST) - 1)]
    return row.get(NAMES.get(m, m), 0)


def main():
    snaps = [json.loads(l) for l in open(sys.argv[1])]
    t0 = min(s["fetched"] for s in snaps)
    start = datetime.fromtimestamp(t0, timezone.utc).date().isoformat()
    end = (datetime.now(timezone.utc).date()).isoformat()
    O = {label: obs(cid, start, end) for cid, label in STATIONS}
    for k, v in O.items():
        print(k, len(v), "hours, last", datetime.fromtimestamp(max(v), timezone.utc) if v else None, file=sys.stderr)
    acc = defaultdict(lambda: defaultdict(lambda: [0, 0.0, 0.0]))   # bucket -> name -> [n, abs, sum]
    for s in snaps:
        f = s["fetched"]
        series = {k[3:]: {r[0]: r[1] for r in v if r[1] is not None} for k, v in s["sources"].items() if k.startswith("om:")}
        if len(series) < 6:
            continue
        hours = sorted(set().union(*[set(v) for v in series.values()]))
        for h in hours:
            lead = (h - f) / 3600
            b = next((a for a, z in BUCKETS if a <= lead < z), None)
            if b is None:
                continue
            vals = {m: v[h] for m, v in series.items() if h in v}
            if len(vals) < 5:
                continue
            cands = dict(vals)
            cands["AppBlend"] = wavg(vals, {m: app_weight(m, lead) for m in vals})
            cands["SummerFit"] = wavg(vals, SUMMER[b])
            cands["Mean"] = sum(vals.values()) / len(vals)
            region = wavg(vals, {m: region_weight(m, lead) for m in vals})
            cands["RegionBlend"] = region
            extra = {k: {r[0]: r[1] for r in v if r[1] is not None} for k, v in s["sources"].items()
                     if k in ("google", "pirate")}
            g = extra.get("google", {}).get(h)
            p = extra.get("pirate", {}).get(h)
            # Paired rows: only hours where Google (or Pirate) was logged, so the comparison with
            # and without it is on the same hours.
            if g is not None and region is not None and lead < 48:
                cands["G:RegionBlend"] = region
                cands["G:Google"] = g
                for w in (0.15, 0.3, 0.5):
                    cands[f"G:Blend+Google{int(w * 100)}%"] = region * (1 - w) + g * w
            if p is not None and region is not None:
                cands["P:RegionBlend"] = region
                cands["P:Pirate"] = p
                cands["P:Blend+Pirate15%"] = region * 0.85 + p * 0.15
            for label, ob in O.items():
                o = ob.get(h)
                if o is None:
                    continue
                for name, v in cands.items():
                    if v is None:
                        continue
                    a = acc[b][name]; a[0] += 1; a[1] += abs(v - o); a[2] += v - o
    for b, _ in BUCKETS:
        if b not in acc:
            continue
        row = sorted(((a[1] / a[0], name, a[0], a[2] / a[0]) for name, a in acc[b].items()), key=lambda x: x[0])
        print(f"\n## lead {b}h+ (pairs={row[0][2]})")
        for mae, name, n, bias in row:
            print(f"  {name:<24} MAE {mae:.2f}  bias {bias:+.2f}")


if __name__ == "__main__":
    main()
