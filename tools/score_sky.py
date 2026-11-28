#!/usr/bin/env python3
"""Does blending the models' cloud cover call the sky better than best-match alone?

The app's sunny/cloudy icon, hourly and for "now" when no station is close, comes from Open-Meteo's
best-match weather code, which is one model's cloud cover. Temperatures use a blend. This checks
whether the same blend (the app's own temperature weights for the region and lead day, nothing
fitted here) or a plain average of the region's models matches what airports report better.

- Observations: METAR sky cover from the Iowa Environmental Mesonet archive (global, no key):
  the most-covered layer, CLR/SKC/NSC/NCD/CAVOK 0 %, FEW 19 %, SCT 44 %, BKN 75 %, OVC/VV 100 %.
  Automatic stations don't see cloud above ~3.7 km (US ASOS), so thin high cloud is missed; the
  "seen" variant counts high cloud at half, as a person would barely notice thin cirrus.
- Forecasts: Open-Meteo's Previous Runs archive (lead days 0-2) for January, April, July and
  October 2026, so every season counts.
- Scored: mean error in % cover, and how often the sky class matches: clear (< 30 %), partly
  (30-69 %), cloudy (>= 70 %), which is roughly the app's sunny / partly cloudy / cloudy.
  By region, and the share of airports where each way beats best-match, so one place can't
  carry it.

Run by .github/workflows/score-sky.yml.

  python3 score_sky.py
"""
import csv, io, json, os, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_regions as sr  # noqa: E402

MONTHS = os.environ.get("SKY_MONTHS", "2026-01,2026-04,2026-07,2026-10").split(",")
LEADS = [0, 1, 2]
EXTRA = ["KHIO", "KORL", "KSFB", "EGLC", "CYHM", "KPDX"]   # near family places
COVER = {"CLR": 0, "SKC": 0, "NSC": 0, "NCD": 0, "FEW": 19, "SCT": 44, "BKN": 75, "OVC": 100, "VV": 100}
TABLE = json.load(open(os.path.join(HERE, "..", "Packages", "WeatherCore", "blend-regions.json")))
IDS = {v: k for k, v in sr.NAMES.items()}


def sky_class(p):
    return 0 if p < 30 else (1 if p < 70 else 2)


def region_table(rid):
    return next((r for r in TABLE["regions"] if r["id"] == rid), TABLE["global"])


def metar_sky(icao):
    q = {"station": icao, "data": ["skyc1", "skyc2", "skyc3", "skyc4", "metar"], "year1": 2026,
         "month1": 1, "day1": 1, "year2": 2026, "month2": 11, "day2": 1, "tz": "Etc/UTC",
         "format": "onlycomma", "latlon": "yes", "missing": "empty", "report_type": [3, 4]}
    url = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?" + sr.urllib.parse.urlencode(q, doseq=True)
    body = sr.fetch(url, f"iem-sky-{icao}.csv", kind="text")
    if not body:
        return {}, None, None
    best, lat, lon = {}, None, None
    for row in csv.DictReader(io.StringIO(body)):
        try:
            ts = datetime.strptime(row["valid"], "%Y-%m-%d %H:%M")
            lat, lon = float(row["lat"]), float(row["lon"])
        except (ValueError, KeyError):
            continue
        covers = [COVER.get((row.get(f"skyc{i}") or "").strip()) for i in range(1, 5)]
        covers = [c for c in covers if c is not None]
        if not covers:
            if "CAVOK" in (row.get("metar") or ""):
                covers = [0]
            else:
                continue
        hour = (ts + timedelta(minutes=30)).replace(minute=0)
        off = abs((ts - hour).total_seconds()) / 60
        if off > 20:
            continue
        k = hour.strftime("%Y-%m-%dT%H:00")
        if k not in best or off < best[k][0]:
            best[k] = (off, max(covers))
    return {k: v for k, (_, v) in best.items()}, lat, lon


def prev_runs(lat, lon, models, month, tag, layered):
    a = date.fromisoformat(month + "-01")
    b = (a.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    vars_ = ["cloud_cover" if n == 0 else f"cloud_cover_previous_day{n}" for n in LEADS]
    if layered:
        vars_ += [f"cloud_cover_{x}_previous_day1" for x in ("low", "mid", "high")]
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
         "models": ",".join(models), "timezone": "GMT", "start_date": a.isoformat(), "end_date": b.isoformat()}
    url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + sr.urllib.parse.urlencode(q)
    units = max(1.0, len(vars_) * len(models) / 10) * max(1.0, ((b - a).days + 1) / 14)
    d = sr.fetch(url, f"sky-{tag}-{month}-{'_'.join(models)}-{int(layered)}.json", units)
    out = {}
    if not d:
        return out
    h = d.get("hourly", {})
    times = h.get("time", [])
    for m in models:
        for v in vars_:
            key = v if len(models) == 1 else f"{v}_{m}"
            vals = h.get(key) or []
            out[(m, v)] = {t: x for t, x in zip(times, vals) if x is not None}
    return out


def weights_for(table, lead):
    row = table["byDay"][min(lead, len(table["byDay"]) - 1)]
    return {IDS[n]: w for n, w in row.items() if n in IDS}


def station(icao):
    obs, lat, lon = metar_sky(icao)
    if not obs or lat is None:
        return icao, None
    rid = sr.region_of(lat, lon)
    table = region_table(rid)
    models = [IDS[n] for n in table["models"] if n in IDS]
    rows = []      # (lead, obs, {variant: forecast})
    for month in MONTHS:
        f = prev_runs(lat, lon, models, month, icao, True)
        bm = prev_runs(lat, lon, ["best_match"], month, icao, True)
        for lead in LEADS:
            v = "cloud_cover" if lead == 0 else f"cloud_cover_previous_day{lead}"
            w = weights_for(table, lead)
            for t, o in obs.items():
                if not t.startswith(month):
                    continue
                b = bm.get(("best_match", v), {}).get(t)
                vals = {m: f.get((m, v), {}).get(t) for m in models}
                vals = {m: x for m, x in vals.items() if x is not None}
                if b is None or len(vals) < 3:
                    continue
                fc = {"best_match": b, "mean": sum(vals.values()) / len(vals)}
                ws = {m: w.get(m, 0) for m in vals}
                if sum(ws.values()) > 0.5:
                    fc["blend"] = sum(vals[m] * ws[m] for m in vals) / sum(ws.values())
                if lead == 1:
                    def seen(m):
                        lo, mi, hi = (f.get((m, f"cloud_cover_{x}_previous_day1"), {}).get(t)
                                      for x in ("low", "mid", "high"))
                        if None in (lo, mi, hi):
                            return None
                        return max(lo, mi, hi * 0.5)
                    s = {m: seen(m) for m in vals}
                    s = {m: x for m, x in s.items() if x is not None}
                    if len(s) >= 3 and sum(ws.get(m, 0) for m in s) > 0.5:
                        fc["blend_seen"] = sum(s[m] * ws[m] for m in s) / sum(ws[m] for m in s)
                    lo, mi, hi = (bm.get(("best_match", f"cloud_cover_{x}_previous_day1"), {}).get(t)
                                  for x in ("low", "mid", "high"))
                    if None not in (lo, mi, hi):
                        fc["best_match_seen"] = max(lo, mi, hi * 0.5)
                rows.append((lead, o, fc))
    return icao, {"region": rid, "rows": rows}


def summarise(rows):
    acc = defaultdict(lambda: [0, 0.0, 0])   # variant -> [n, abs err, class hits]
    for _, o, fc in rows:
        for k, x in fc.items():
            a = acc[k]
            a[0] += 1
            a[1] += abs(x - o)
            a[2] += sky_class(x) == sky_class(o)
    return {k: (n, e / n, h / n) for k, (n, e, h) in acc.items() if n}


def main():
    if os.environ.get("SKY_STAGE") == "obs":
        with ThreadPoolExecutor(6) as ex:
            list(ex.map(metar_sky, sr.STATIONS + EXTRA))
        return
    with ThreadPoolExecutor(4) as ex:
        results = dict(ex.map(station, sr.STATIONS + EXTRA))
    results = {k: v for k, v in results.items() if v and v["rows"]}
    report = {"by_region": {}, "stations": {}}
    variants = ["best_match", "mean", "blend", "best_match_seen", "blend_seen"]
    print(f"{len(results)} airports with sky reports and forecasts\n")
    for lead in LEADS:
        print(f"=== lead day {lead} (class hit rate %, mean error % cover; 'wins' = airports beating best-match on hits)")
        regions = sorted({v["region"] for v in results.values()})
        for rid in regions + ["ALL"]:
            sts = [k for k, v in results.items() if rid == "ALL" or v["region"] == rid]
            rows = [r for k in sts for r in results[k]["rows"] if r[0] == lead]
            if not rows:
                continue
            s = summarise(rows)
            per = {k: summarise([r for r in results[k]["rows"] if r[0] == lead]) for k in sts}
            line = f"  {rid:10s} n={len(rows):6d}"
            for vname in variants:
                if vname not in s:
                    continue
                n, e, h = s[vname]
                base = "best_match_seen" if vname == "blend_seen" else "best_match"
                wins = sum(1 for p in per.values() if vname in p and base in p and p[vname][2] > p[base][2])
                line += f" | {vname} {100*h:.1f}% {e:.1f}" + (f" w{wins}/{len(per)}" if vname != base else "")
                report["by_region"].setdefault(f"{rid}-d{lead}", {})[vname] = {"n": n, "mae": e, "hits": h, "wins": wins, "of": len(per)}
            print(line)
        print()
    for k, v in results.items():
        report["stations"][k] = {"region": v["region"],
                                 **{f"d{lead}": summarise([r for r in v["rows"] if r[0] == lead]) for lead in LEADS}}
    print("Family-place airports, lead 1 (hits %): " + ", ".join(
        f"{k} bm {100*report['stations'][k]['d1'].get('best_match', (0,0,0))[2]:.0f} / blend "
        f"{100*report['stations'][k]['d1'].get('blend', (0,0,0))[2]:.0f}" for k in EXTRA + ["CYYZ", "OPLA", "EGLL"]
        if k in report["stations"]))
    with open("sky-report.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
