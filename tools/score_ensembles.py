#!/usr/bin/env python3
"""Score the ensemble log (tools/log_ensembles.py) against what airports reported.

For each saved snapshot, airport and hour: was it wet (the METAR reported DZ, RA, SN, SG, PL, GR,
GS, UP or a shower/thunderstorm with rain)? Each chance is scored with the Brier score (lower is
better), by lead time and region:

  best_match       Open-Meteo's chance, what the app starts from
  app_today        roughly the app's mix: 0.6 x best-match + 0.4 x share of blend models wet
  blend_share      share of the region's blend models with >= 0.2 mm
  ens:<model>      share of that ensemble's members wet
  ens_pool         all ensembles' members pooled (each ensemble counted once, equally)
  mix_<w>          w x ens_pool + (1 - w) x best_match, w fitted on the other regions

Daily (any wet hour in the local-ish UTC day) is scored the same way with each chance's peak hour.

  python3 score_ensembles.py LOG_DIR
"""
import csv, gzip, io, json, os, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_regions as sr  # noqa: E402

WET = ("DZ", "RA", "SN", "SG", "PL", "GR", "GS", "UP", "IC")
BUCKETS = [(0, 12), (12, 24), (24, 48), (48, 72), (72, 120)]
WEIGHTS = [0, 0.25, 0.5, 0.75, 1.0]


def wet_hours(icao, start, end):
    """{unix hour: wet?} from METAR present weather (any report in the hour)."""
    q = {"station": icao, "data": "wxcodes", "year1": start.year, "month1": start.month, "day1": start.day,
         "year2": end.year, "month2": end.month, "day2": end.day, "tz": "Etc/UTC", "format": "onlycomma",
         "missing": "empty", "report_type": [3, 4]}
    url = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?" + sr.urllib.parse.urlencode(q, doseq=True)
    body = sr.fetch(url, f"iem-wx-{icao}-{start:%Y%m%d}-{end:%Y%m%d}.csv", kind="text")
    out = {}
    for row in csv.DictReader(io.StringIO(body or "")):
        try:
            ts = datetime.strptime(row["valid"], "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
        except (ValueError, KeyError):
            continue
        h = int(ts.replace(minute=0).timestamp())
        wx = row.get("wxcodes") or ""
        wet = any(c in wx for c in WET) and "VC" not in wx.split()[0] if wx else False
        out[h] = out.get(h, False) or wet
    return out


def main():
    log = sys.argv[1]
    snaps = []
    for name in sorted(os.listdir(log)):
        if name.endswith(".json.gz"):
            with gzip.open(os.path.join(log, name), "rt") as f:
                snaps.append(json.load(f))
    places = json.load(open(os.path.join(log, "stations.json")))
    if not snaps:
        print("no snapshots")
        return
    first = datetime.fromtimestamp(min(s["fetched"] for s in snaps), timezone.utc) - timedelta(days=1)
    last = datetime.fromtimestamp(max(s["fetched"] for s in snaps), timezone.utc) + timedelta(days=6)
    last = min(last, datetime.now(timezone.utc))
    truth = {k: wet_hours(k, first.date(), last.date()) for k in places}
    rows = []     # (region, icao, lead, wet, {name: p})
    for s in snaps:
        for icao, rec in s["stations"].items():
            if icao not in places:
                continue
            rid = sr.region_of(*places[icao])
            t0 = rec["t0"]
            for i in range(len(rec.get("bm_pop", []))):
                h = t0 + 3600 * i
                if h not in truth[icao] or rec["bm_pop"][i] is None:
                    continue
                p = {"best_match": rec["bm_pop"][i] / 100}
                bl = [v[i] for v in rec.get("blend", {}).values() if i < len(v) and v[i] is not None]
                if len(bl) >= 3:
                    p["blend_share"] = sum(x >= 0.2 for x in bl) / len(bl)
                    p["app_today"] = 0.6 * p["best_match"] + 0.4 * p["blend_share"]
                ens = []
                for m, e in rec.get("ens", {}).items():
                    if i < len(e["wet"]) and e["wet"][i] is not None:
                        p["ens:" + m] = e["wet"][i] / 100
                        ens.append(e["wet"][i] / 100)
                if len(ens) >= 2:
                    p["ens_pool"] = sum(ens) / len(ens)
                rows.append((rid, icao, i, truth[icao][h], p))
    print(f"{len(snaps)} snapshots, {len(rows)} scored hours, base rate wet "
          f"{sum(r[3] for r in rows) / max(1, len(rows)):.3f}\n")

    def brier(sel, name):
        xs = [(r[4][name] - r[3]) ** 2 for r in sel if name in r[4]]
        return (sum(xs) / len(xs), len(xs)) if xs else (None, 0)

    names = sorted({k for r in rows for k in r[4]})
    regions = sorted({r[0] for r in rows})
    report = {}
    for a, b in BUCKETS:
        sel = [r for r in rows if a <= r[2] < b]
        print(f"=== hours {a}-{b - 1} (Brier)")
        for name in names:
            v, n = brier(sel, name)
            if v is not None:
                print(f"  {name:36s} {v:.4f}  n={n}")
                report.setdefault(f"{a}-{b}", {})[name] = v
        # mix fitted on the other regions, scored on each region
        tot = defaultdict(float)
        cnt = 0
        for rid in regions:
            train = [r for r in sel if r[0] != rid and "ens_pool" in r[4]]
            test = [r for r in sel if r[0] == rid and "ens_pool" in r[4]]
            if not train or not test:
                continue
            def b_of(rs, w):
                return sum((w * r[4]["ens_pool"] + (1 - w) * r[4]["best_match"] - r[3]) ** 2 for r in rs)
            w = min(WEIGHTS, key=lambda w: b_of(train, w))
            tot["mix_heldout"] += b_of(test, w)
            tot["best_match"] += sum((r[4]["best_match"] - r[3]) ** 2 for r in test)
            tot["app_today"] += sum((r[4].get("app_today", r[4]["best_match"]) - r[3]) ** 2 for r in test)
            cnt += len(test)
            print(f"    {rid:10s} mix weight on ensembles {w}  "
                  f"held-out {b_of(test, w) / len(test):.4f} vs best_match "
                  f"{sum((r[4]['best_match'] - r[3]) ** 2 for r in test) / len(test):.4f}")
        if cnt:
            print("  held out by region: " + "  ".join(f"{k} {v / cnt:.4f}" for k, v in tot.items()))
            report.setdefault(f"{a}-{b}", {})["heldout"] = {k: v / cnt for k, v in tot.items()}
        print()
    with open("ensemble-report.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
