#!/usr/bin/env python3
"""Which chance of rain is closest to what happened: Open-Meteo's, or the share of models that are wet?

The app's "chance of rain" comes from Open-Meteo's best-match precipitation_probability. The
blend already downloads 8 models' precipitation, so the share of them that are wet is free.
This scores both as probabilities (Brier score, lower is better) against ECCC station gauges,
hourly (PRECIP_AMOUNT) and daily (TOTAL_PRECIPITATION), for lead days 0-5, and tries mixes.

  python3 score_precip.py
"""
import json, os, sys, urllib.parse
from collections import defaultdict
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_bias as sb  # noqa: E402  (sets EXTRA so the AI model is included)
import score_models as sm  # noqa: E402

MODELS = ["gem_seamless", "gem_hrdps_continental", "gfs_seamless", "gfs_hrrr", "ecmwf_ifs025",
          "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless"]
HOUR_WET_OBS = 0.2     # mm in the hour at the gauge
HOUR_WET_MODEL = 0.2   # same as ModelBlend's "wet" (OpenMeteoProvider.parseBlend)
DAY_WET = 0.5
MIXES = [0.0, 0.25, 0.5, 0.75, 1.0]   # weight of the model share; rest is Open-Meteo's chance


def hourly_precip_obs(cid):
    rng = f"{sm.START.isoformat()}T00:00:00/{(sm.END + timedelta(days=1)).isoformat()}T06:00:00"
    feats = sm.ogc_all("climate-hourly", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"hly-{cid}")
    out = {}
    for f in feats:
        p = f["properties"]
        v = p.get("PRECIP_AMOUNT")
        if v is None or not p.get("UTC_DATE"):
            continue
        out[sm.parse_time(p["UTC_DATE"]).strftime("%Y-%m-%dT%H:00")] = float(v)
    return out


def probabilities(lat, lon, cid):
    """{lead: {utc hour: best-match precipitation_probability}} from the previous-runs API."""
    out = defaultdict(dict)
    vars_ = ["precipitation_probability"] + [f"precipitation_probability_previous_day{n}" for n in sm.LEADS[1:]]
    for a, b in sm.months():
        q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "hourly": ",".join(vars_),
             "timezone": "GMT", "start_date": a.isoformat(), "end_date": (b + timedelta(days=1)).isoformat()}
        url = "https://previous-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
        try:
            d = sm.get_json(url, f"pop-{cid}-{a.isoformat()}.json")
        except Exception as e:
            print("  pop failed", a, e, file=sys.stderr)
            continue
        h = d.get("hourly", {})
        for n in sm.LEADS:
            key = "precipitation_probability" + ("" if n == 0 else f"_previous_day{n}")
            for t, v in zip(h.get("time", []), h.get(key) or []):
                if v is not None:
                    out[n][t] = v / 100
    return out


def brier(pairs):
    return round(sum((p - o) ** 2 for p, o in pairs) / len(pairs), 4) if pairs else None


def reliability(pairs):
    bins = defaultdict(lambda: [0, 0])
    for p, o in pairs:
        b = min(int(p * 10), 9)
        bins[b][0] += 1; bins[b][1] += o
    return {f"{b * 10}-{b * 10 + 10}%": (n, round(w / n, 2)) for b, (n, w) in sorted(bins.items())}


def main():
    stations = sb.discover()[:5]
    hourly = defaultdict(list)   # lead -> [(p_om, share, wet)]
    daily = defaultdict(list)
    for cid, label, lat, lon, _ in stations:
        _, op = sm.observations(cid)
        oh = hourly_precip_obs(cid)
        print(label, len(oh), "hourly gauge readings,", len(op), "days", file=sys.stderr)
        fc = sm.forecasts(lat, lon, cid)
        pop = probabilities(lat, lon, cid)
        if not pop:
            print("  no probabilities", file=sys.stderr); continue
        for n in sm.LEADS:
            dp, dshare = defaultdict(list), defaultdict(lambda: defaultdict(float))
            dcount = defaultdict(lambda: defaultdict(int))
            for t, p in pop[n].items():
                share = [fc[m][n][t][1] >= HOUR_WET_MODEL for m in MODELS
                         if t in fc.get(m, {}).get(n, {}) and fc[m][n][t][1] is not None]
                if len(share) < 4:
                    continue
                s = sum(share) / len(share)
                if t in oh:
                    hourly[n].append((p, s, oh[t] >= HOUR_WET_OBS))
                day = sm.lst_day(t)
                dp[day].append(p)
                for m in MODELS:
                    v = fc.get(m, {}).get(n, {}).get(t)
                    if v and v[1] is not None:
                        dshare[day][m] += v[1]; dcount[day][m] += 1
            for day, ps in dp.items():
                if len(ps) < 24 or day.isoformat() not in op or not (sm.START <= day <= sm.END):
                    continue
                ms = [dshare[day][m] >= DAY_WET for m in MODELS if dcount[day][m] >= 24]
                if len(ms) < 4:
                    continue
                daily[n].append((max(ps), sum(ms) / len(ms), op[day.isoformat()] >= DAY_WET))

    report = {}
    for name, rows in (("hourly", hourly), ("daily", daily)):
        report[name] = {}
        for n in sm.LEADS:
            r = rows[n]
            if not r:
                continue
            res = {"n": len(r), "observed_wet": round(sum(o for *_, o in r) / len(r), 3)}
            for w in MIXES:
                res[f"mix{w}"] = brier([((1 - w) * p + w * s, o) for p, s, o in r])
            res["reliability_open_meteo"] = reliability([(p, o) for p, _, o in r])
            res["reliability_share"] = reliability([(s, o) for _, s, o in r])
            res["reliability_mix0.5"] = reliability([(0.5 * p + 0.5 * s, o) for p, s, o in r])
            report[name][n] = res
    with open("precip-results.json", "w") as f:
        json.dump(report, f, indent=1)
    print("Brier score (lower is better). mix0.0 = Open-Meteo's chance only, mix1.0 = share of models wet")
    for name in ("hourly", "daily"):
        print(f"\n## {name}")
        for n, res in report[name].items():
            print(f"  day{n} n={res['n']} wet={res['observed_wet']} " +
                  " ".join(f"mix{w}:{res[f'mix{w}']}" for w in MIXES))
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
