#!/usr/bin/env python3
"""Do the daily high and low allowances (ModelBlend.highAllowance +0.4°, lowAllowance 0.5°) hold
around the world, or only near Milton where they were fitted?

The app's high is the warmest blended hour plus 0.4°, its low the coldest minus 0.5°. Both were
fitted at six Ontario stations (tools/score_extremes.py). This checks them at airports on six
continents, against official daily extremes:

- Truth: NOAA's Global Historical Climatology Network daily TMAX / TMIN (official, worldwide,
  free) at the GHCN station within 3 km of each airport.
- Day definitions differ by country (some take the low overnight, some the high 06-18 UTC). So
  each station is checked first against its own hourly METARs: the recorded high should sit a
  little above its warmest hour (and the low a little below its coldest). Stations where the
  median gap is outside -0.3..1.5° measure a different day and are left out.
- Forecasts: the app's blend (its own weights for the region and lead day) from Open-Meteo's
  Previous Runs archive, lead days 1 and 2, local calendar days, six months across 2026.
- The blend's extreme is built as the app builds it (Forecast.applying: warmest blended hour,
  lifted by the blend of each model's own high, and the low dropped by half that way), before
  the allowance.
- Ways tried: no allowance, today's constants, one worldwide constant and one per region, both
  fitted on the other airports and scored on the one left out.

Run by .github/workflows/score-highlow.yml.

  python3 score_highlow.py
"""
import csv, io, json, os, statistics, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_regions as sr  # noqa: E402

MONTHS = os.environ.get("HL_MONTHS", "2026-01,2026-03,2026-05,2026-07,2026-09,2026-10").split(",")
LEADS = [1, 2]
HIGH, LOW = 0.4, 0.5          # ModelBlend.highAllowance / lowAllowance today
EXTRA = ["KHIO", "KORL", "KSFB", "EGLC", "CYHM", "KPDX"]
TABLE = json.load(open(os.path.join(HERE, "..", "Packages", "WeatherCore", "blend-regions.json")))
IDS = {v: k for k, v in sr.NAMES.items()}
GHCN = "https://www.ncei.noaa.gov/pub/data/ghcn/daily/ghcnd-stations.txt"
GHCN_DATA = ("https://www.ncei.noaa.gov/access/services/data/v1?dataset=daily-summaries&stations={}"
             "&startDate=2026-01-01&endDate=2026-11-20&dataTypes=TMAX,TMIN&format=csv&units=metric")


def km(a, b, c, d):
    import math
    p = math.pi / 180
    x = (d - b) * p * math.cos((a + c) / 2 * p)
    return 6371 * math.hypot(x, (c - a) * p)


_ghcn = []


def ghcn_list():
    if not _ghcn:
        body = sr.fetch(GHCN, "ghcnd-stations.txt", kind="text") or ""
        for line in body.splitlines():
            try:
                _ghcn.append((line[0:11], float(line[12:20]), float(line[21:30])))
            except ValueError:
                pass
    return _ghcn


def ghcn_daily(sid):
    body = sr.fetch(GHCN_DATA.format(sid), f"ghcn-{sid}.csv", kind="text")
    out = {}
    if not body:
        return out
    for row in csv.DictReader(io.StringIO(body)):
        d = row.get("DATE", "")
        if not d.startswith("2026"):
            continue
        def val(k):
            v = (row.get(k) or "").strip()
            try:
                return float(v)
            except ValueError:
                return None
        out[d] = (val("TMAX"), val("TMIN"))
    return out


def region_table(rid):
    return next((r for r in TABLE["regions"] if r["id"] == rid), TABLE["global"])


def prev_runs(lat, lon, models, month, tag):
    a = date.fromisoformat(month + "-01")
    b = (a.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    vars_ = [f"temperature_2m_previous_day{n}" for n in LEADS]
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
         "models": ",".join(models), "timezone": "auto", "timeformat": "unixtime",
         "start_date": a.isoformat(), "end_date": b.isoformat()}
    url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + sr.urllib.parse.urlencode(q)
    units = max(1.0, len(vars_) * len(models) / 10) * max(1.0, ((b - a).days + 1) / 14)
    d = sr.fetch(url, f"hl-{tag}-{month}-{'_'.join(models)}.json", units)
    if not d:
        return {}, 0
    h = d.get("hourly", {})
    out = {}
    for m in models:
        for v in vars_:
            vals = h.get(v if len(models) == 1 else f"{v}_{m}") or []
            out[(m, v)] = dict(zip(h.get("time", []), vals))
    return out, d.get("utc_offset_seconds", 0)


def station(icao):
    hourly, lat, lon = sr.metars(icao)
    if lat is None:
        return icao, None
    near = [(km(lat, lon, a, b), sid) for sid, a, b in ghcn_list() if abs(a - lat) < 0.1 and abs(b - lon) < 0.15]
    near = [x for x in near if x[0] <= 3]
    if not near:
        return icao, None
    sid, truth = None, {}
    for _, cand in sorted(near)[:5]:
        if cand.startswith("US1"):        # CoCoRaHS rain gauges: no temperatures
            continue
        t = ghcn_daily(cand)
        if sum(1 for x, _ in t.values() if x is not None) >= 100:
            sid, truth = cand, t
            break
    if not truth:
        return icao, None
    rid = sr.region_of(lat, lon)
    table = region_table(rid)
    models = [IDS[n] for n in table["models"] if n in IDS]
    rows = []      # (lead, day, obs_max, obs_min, blend_max, blend_min)
    offset = None
    for month in MONTHS:
        f, offset = prev_runs(lat, lon, models, month, icao)
        if not f:
            continue
        for lead in LEADS:
            v = f"temperature_2m_previous_day{lead}"
            row = table["byDay"][min(lead, len(table["byDay"]) - 1)]
            w = {IDS[n]: x for n, x in row.items() if n in IDS}
            byday = defaultdict(list)          # day -> [(blend, {model: temp})]
            times = sorted({t for m in models for t in f.get((m, v), {})})
            for t in times:
                vals = {m: f[(m, v)].get(t) for m in models if f.get((m, v), {}).get(t) is not None}
                ws = {m: w.get(m, 0) for m in vals}
                if sum(ws.values()) < 0.5:
                    continue
                b = sum(vals[m] * ws[m] for m in vals) / sum(ws.values())
                day = datetime.fromtimestamp(t + offset, timezone.utc).strftime("%Y-%m-%d")
                byday[day].append((b, vals))
            for day, hrs in byday.items():
                if len(hrs) < 22 or day not in truth:
                    continue
                tx, tn = truth[day]
                raw_hi = max(b for b, _ in hrs)
                raw_lo = min(b for b, _ in hrs)
                # As the app (Forecast.applying): the blend of each model's own max/min lifts the
                # high (fully) and drops the low (half) when models peak at different hours.
                full = [m for m in models if all(m in vals for _, vals in hrs)]
                ws = {m: w.get(m, 0) for m in full}
                hi, lo = raw_hi, raw_lo
                if sum(ws.values()) > 0.5:
                    mx = sum(max(vals[m] for _, vals in hrs) * ws[m] for m in full) / sum(ws.values())
                    mn = sum(min(vals[m] for _, vals in hrs) * ws[m] for m in full) / sum(ws.values())
                    hi = raw_hi + max(0, mx - raw_hi)
                    lo = raw_lo - 0.5 * max(0, raw_lo - mn)
                rows.append((lead, day, tx, tn, hi, lo))
    # Sampling check: the station's own warmest/coldest METAR hour on its local day vs GHCN.
    gx, gn = [], []
    if offset is not None:
        byday = defaultdict(list)
        for k, t in hourly.items():
            ts = datetime.strptime(k, "%Y-%m-%dT%H:00").replace(tzinfo=timezone.utc)
            byday[(ts + timedelta(seconds=offset)).strftime("%Y-%m-%d")].append(t)
        for day, temps in byday.items():
            if len(temps) >= 22 and day in truth:
                tx, tn = truth[day]
                if tx is not None:
                    gx.append(tx - max(temps))
                if tn is not None:
                    gn.append(min(temps) - tn)
    return icao, {"region": rid, "ghcn": sid, "rows": rows,
                  "gap_high": statistics.median(gx) if len(gx) > 30 else None,
                  "gap_low": statistics.median(gn) if len(gn) > 30 else None}


def errs(rows, lead, kind):
    out = []
    for r in rows:
        if r[0] != lead:
            continue
        o = r[2] if kind == "high" else r[3]
        f = r[4] if kind == "high" else r[5]
        if o is not None:
            out.append(o - f)      # what has to be added to the blend's extreme
    return out


def main():
    if os.environ.get("HL_STAGE") == "obs":
        ghcn_list()
        with ThreadPoolExecutor(6) as ex:
            list(ex.map(sr.metars, sr.STATIONS + EXTRA))
        return
    with ThreadPoolExecutor(4) as ex:
        res = dict(ex.map(station, sr.STATIONS + EXTRA))
    res = {k: v for k, v in res.items() if v and v["rows"]}
    print(f"{len(res)} airports with a GHCN station within 3 km\n")
    print("Sampling check (median GHCN high - warmest METAR hour / coldest hour - GHCN low):")
    keep = {"high": [], "low": []}
    for k, v in sorted(res.items()):
        gh, gl = v["gap_high"], v["gap_low"]
        okh = gh is not None and -0.3 <= gh <= 1.5
        okl = gl is not None and -0.3 <= gl <= 1.5
        if okh:
            keep["high"].append(k)
        if okl:
            keep["low"].append(k)
        print(f"  {k} {v['region']:9s} {v['ghcn']}  high {gh if gh is None else round(gh, 2)}{'' if okh else ' (left out)'}"
              f"  low {gl if gl is None else round(gl, 2)}{'' if okl else ' (left out)'}")
    report = {}
    for kind, now_c in (("high", HIGH), ("low", -LOW)):
        print(f"\n=== {kind}s  (MAE °C; 'needed' = mean amount to add to the blend's extreme)")
        for lead in LEADS:
            st = {k: errs(res[k]["rows"], lead, kind) for k in keep[kind]}
            st = {k: e for k, e in st.items() if len(e) >= 30}
            allv = [x for e in st.values() for x in e]
            if not allv:
                continue
            def mae(e, c):
                return sum(abs(x - c) for x in e) / len(e)
            tot = defaultdict(float)
            n = 0
            byreg = defaultdict(lambda: defaultdict(float))
            byreg_n = defaultdict(int)
            for k, e in st.items():
                others = [x for j, ee in st.items() if j != k for x in ee]
                same = [x for j, ee in st.items() if j != k and res[j]["region"] == res[k]["region"] for x in ee]
                cw = statistics.median(others)
                cr = statistics.median(same) if len(same) >= 300 else cw
                r = res[k]["region"]
                for name, c in (("none", 0.0), ("today", now_c), ("world", cw), ("region", cr)):
                    tot[name] += mae(e, c) * len(e)
                    byreg[r][name] += mae(e, c) * len(e)
                    byreg[r]["needed"] += sum(e)
                n += len(e)
                byreg_n[r] += len(e)
            print(f"  lead {lead}: n={n}  needed {sum(allv)/len(allv):+.2f} (median {statistics.median(allv):+.2f})  "
                  + "  ".join(f"{k} {v/n:.3f}" for k, v in tot.items()))
            report[f"{kind}-d{lead}"] = {"n": n, "needed_mean": sum(allv) / len(allv),
                                        "needed_median": statistics.median(allv),
                                        **{k: v / n for k, v in tot.items()}, "regions": {}}
            for r in sorted(byreg):
                m = byreg_n[r]
                print(f"     {r:10s} n={m:5d} needed {byreg[r]['needed']/m:+.2f}  " +
                      "  ".join(f"{k} {byreg[r][k]/m:.3f}" for k in ("none", "today", "world", "region")))
                report[f"{kind}-d{lead}"]["regions"][r] = {"n": m, "needed": byreg[r]["needed"] / m,
                                                         **{k: byreg[r][k] / m for k in ("none", "today", "world", "region")}}
    with open("highlow-report.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
