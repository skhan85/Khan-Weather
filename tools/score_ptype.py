#!/usr/bin/env python3
"""Rain or snow? Which rule calls it best, against what airport observers reported.

For every hour that Toronto Pearson or Hamilton Airport reported rain/drizzle or snow (ECCC
climate-hourly WEATHER_ENG_DESC), Nov 2025-Apr 2026, compares rules for the forecast's type:
  - best_match: Open-Meteo's single best-match model (what the app uses now)
  - vote:       the share of the blend's models that call snow, among those that are wet
  - vote_w:     the same, weighted by the app's blend weights for that lead day
  - temp<=X:    snow when the blended temperature is at or below X °C
  - vote+temp:  the vote, with the blended temperature deciding when no model is wet
A model calls snow when its snowfall (as water: cm / 0.7) is at least half its precipitation.
Run by .github/workflows/score-ptype.yml. Pure standard library; caches in ./verify-cache.
"""
import json, os, sys, urllib.parse
from collections import defaultdict
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402

START, END = date(2025, 11, 1), date(2026, 4, 30)
STATIONS = [("6158731", "Toronto Pearson"), ("6153193", "Hamilton Airport")]
MODELS = ["gem_seamless", "gem_hrdps_continental", "gfs_seamless", "ecmwf_ifs025", "ecmwf_aifs025_single",
          "icon_seamless", "ukmo_seamless", "best_match"]
BLEND = MODELS[:-1]
LEADS = [0, 1, 2, 3]
# ModelBlend.byDay (today's row from PR #55), Open-Meteo ids.
BY_DAY = [
    {"icon_seamless": 0.30, "ecmwf_ifs025": 0.20, "gfs_seamless": 0.15, "gem_seamless": 0.15,
     "ukmo_seamless": 0.10, "ecmwf_aifs025_single": 0.10},
    {"ecmwf_aifs025_single": 0.28, "icon_seamless": 0.22, "ukmo_seamless": 0.185, "gem_hrdps_continental": 0.12,
     "gem_seamless": 0.10, "ecmwf_ifs025": 0.04, "gfs_seamless": 0.05},
    {"ecmwf_aifs025_single": 0.35, "gfs_seamless": 0.23, "icon_seamless": 0.18, "ukmo_seamless": 0.125,
     "ecmwf_ifs025": 0.075, "gem_seamless": 0.04},
    {"ecmwf_aifs025_single": 0.43, "gfs_seamless": 0.235, "ukmo_seamless": 0.11, "icon_seamless": 0.095,
     "ecmwf_ifs025": 0.085, "gem_seamless": 0.045},
]
WET_MM = 0.05


def months():
    d = START
    while d <= END:
        nxt = (d.replace(day=28) + timedelta(days=4)).replace(day=1)
        yield d, min(nxt - timedelta(days=1), END)
        d = nxt


def obs_types(cid):
    rng = f"{START.isoformat()}T00:00:00/{(END + timedelta(days=1)).isoformat()}T06:00:00"
    feats = sm.ogc_all("climate-hourly", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"hly-ptype-{cid}")
    out = {}
    for f in feats:
        p = f["properties"]
        w = (p.get("WEATHER_ENG_DESC") or "").lower()
        if not w:
            continue
        snow = "snow" in w or "ice crystals" in w
        rain = "rain" in w or "drizzle" in w
        frozen_mix = "freezing" in w or "ice pellets" in w
        if not (snow or rain or frozen_mix):
            continue
        ut = sm.parse_time(p["UTC_DATE"]) if p.get("UTC_DATE") else sm.parse_time(p["LOCAL_DATE"]) + timedelta(hours=5)
        kind = "mixed" if frozen_mix or (snow and rain) else ("snow" if snow else "rain")
        out[ut.strftime("%Y-%m-%dT%H:00")] = kind
    return out


def forecasts(lat, lon, cid):
    """{model: {lead: {utc hour: (temp, precip, snowfall)}}}"""
    out = defaultdict(lambda: defaultdict(dict))
    vars_ = []
    for base in ("temperature_2m", "precipitation", "snowfall"):
        vars_.append(base)
        vars_ += [f"{base}_previous_day{n}" for n in LEADS[1:]]
    for a, b in months():
        q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
             "models": ",".join(MODELS), "timezone": "GMT",
             "start_date": a.isoformat(), "end_date": (b + timedelta(days=1)).isoformat()}
        url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
        h = sm.get_json(url, f"ptype-{cid}-{a.isoformat()}.json")["hourly"]
        for m in MODELS:
            for n in LEADS:
                suf = "" if n == 0 else f"_previous_day{n}"
                ts = h.get(f"temperature_2m{suf}_{m}") or []
                ps = h.get(f"precipitation{suf}_{m}") or []
                ss = h.get(f"snowfall{suf}_{m}") or []
                for i, t in enumerate(h["time"]):
                    v = (ts[i] if i < len(ts) else None, ps[i] if i < len(ps) else None,
                         ss[i] if i < len(ss) else None)
                    if v[0] is not None:
                        out[m][n][t] = v
        print(f"  {cid} {a:%Y-%m} ok", file=sys.stderr)
    return out


def model_call(v):
    """'snow', 'rain' or None (dry or no data)."""
    t, p, s = v
    if p is None or p < WET_MM:
        return None
    if s is None:
        return None
    return "snow" if (s / 0.7) >= 0.5 * p else "rain"


class Score:
    def __init__(s): s.hit = defaultdict(int); s.n = defaultdict(int)
    def add(s, obs, call):
        s.n[obs] += 1
        s.hit[obs] += call == obs
    def row(s):
        r, sn = s.n["rain"], s.n["snow"]
        acc = (s.hit["rain"] + s.hit["snow"]) / max(r + sn, 1)
        return (f"all {acc:.3f}  rain {s.hit['rain'] / max(r, 1):.3f} (n={r})  "
                f"snow {s.hit['snow'] / max(sn, 1):.3f} (n={sn})"), acc


def main():
    rules = defaultdict(lambda: defaultdict(Score))  # rules[lead][name]
    mixed = defaultdict(lambda: defaultdict(int))
    for cid, label in STATIONS:
        lat, lon = sm.station_coords(cid)
        obs = obs_types(cid)
        print(label, "wet hours:", {k: list(obs.values()).count(k) for k in ("rain", "snow", "mixed")}, file=sys.stderr)
        fc = forecasts(lat, lon, cid)
        for t, kind in obs.items():
            for n in LEADS:
                vals = {m: fc[m][n].get(t) for m in MODELS}
                if any(vals[m] is None for m in ("best_match",)):
                    continue
                present = {m: v for m, v in vals.items() if m in BLEND and v is not None}
                w = BY_DAY[n]
                tot = sum(w.get(m, 0) for m in present)
                if tot < 0.6:
                    continue
                blend_t = sum(present[m][0] * w.get(m, 0) for m in present) / tot
                calls = {m: model_call(v) for m, v in present.items()}
                wet = {m: c for m, c in calls.items() if c}
                if kind == "mixed":
                    mixed[n][("snow" if sum(c == "snow" for c in wet.values()) * 2 > len(wet) else "rain") if wet else "dry"] += 1
                    continue
                bm = model_call(vals["best_match"]) or ("snow" if vals["best_match"][0] <= 0.5 else "rain")
                rules[n]["best_match (now)"].add(kind, bm)
                temp_call = lambda x: "snow" if blend_t <= x else "rain"
                for x in (0.0, 0.5, 1.0, 1.5, 2.0):
                    rules[n][f"temp<={x}"].add(kind, temp_call(x))
                if wet:
                    share = sum(c == "snow" for c in wet.values()) / len(wet)
                    ws = sum(w.get(m, 0) for m in wet)
                    wshare = (sum(w.get(m, 0) for m, c in wet.items() if c == "snow") / ws) if ws else share
                    vote, vote_w = ("snow" if share >= 0.5 else "rain"), ("snow" if wshare >= 0.5 else "rain")
                else:
                    vote = vote_w = None
                rules[n]["vote"].add(kind, vote)
                rules[n]["vote+temp<=1"].add(kind, vote or temp_call(1.0))
                rules[n]["vote_w+temp<=1"].add(kind, vote_w or temp_call(1.0))
                # Vote, but a clearly warm or cold blend overrules it.
                hybrid = vote or temp_call(1.0)
                if blend_t >= 3:
                    hybrid = "rain"
                elif blend_t <= -2:
                    hybrid = "snow"
                rules[n]["vote+temp, -2/+3 guard"].add(kind, hybrid)
    report = {}
    for n in LEADS:
        print(f"\n## lead day {n}")
        report[n] = {}
        for name, s in sorted(rules[n].items(), key=lambda kv: -kv[1].row()[1]):
            text, acc = s.row()
            report[n][name] = text
            print(f"  {name:<26} {text}")
        print(f"  mixed/freezing hours, majority call: {dict(mixed[n])}")
    with open("ptype-results.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
