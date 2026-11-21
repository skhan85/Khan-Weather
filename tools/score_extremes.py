#!/usr/bin/env python3
"""Does the app's daily high run low (and its low run high) against what stations record?

The app's high and low are the warmest and coldest of the blended hourly temperatures. A
station's daily high is the warmest minute of the day, which usually falls between two hours,
so a high taken from hourly values should run a little low wherever it is. This measures that:

  - sampling: the station's own warmest hourly reading vs its recorded daily high
              (no forecast involved, so it should be about the same at every station)
  - app:      the blend's warmest hour vs the recorded high, by lead day
  - fixed:    the same with a constant added to highs and taken off lows, fitted on the
              other stations and tested on the one left out (does it travel?)

Run by .github/workflows/score-extremes.yml (by hand). Reuses score_bias's stations and cache.
"""
import json, os, sys
from collections import defaultdict
from datetime import datetime, timezone

os.environ.setdefault("EXTRA", "ecmwf_aifs025_single")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402
import score_bias as sb    # noqa: E402

# ModelBlend.byDay as the app has it now (today's row from PR #55).
sb.BY_DAY[0] = {"icon_seamless": 0.30, "ecmwf_ifs025": 0.20, "gfs_hrrr": 0.15, "gem_seamless": 0.15,
                "ukmo_seamless": 0.10, "ecmwf_aifs025_single": 0.10}


def daily_obs(cid):
    rng = f"{sm.START.isoformat()}T00:00:00/{sm.END.isoformat()}T23:59:59"
    feats = sm.ogc_all("climate-daily", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"dly-{cid}")
    out = {}
    for f in feats:
        p = f["properties"]
        hi, lo = p.get("MAX_TEMPERATURE"), p.get("MIN_TEMPERATURE")
        if hi is not None and lo is not None:
            out[sm.parse_time(p["LOCAL_DATE"]).date()] = (float(hi), float(lo))
    return out


def blend_by_day(fc):
    """{lead: {LST date: [blended hourly temps]}}"""
    out = defaultdict(lambda: defaultdict(list))
    hours = set()
    for m in fc.values():
        for series in m.values():
            hours.update(series)
    for t in hours:
        d = sm.lst_day(t)
        for n, w in enumerate(sb.BY_DAY):
            s = tot = 0.0
            for m, wm in w.items():
                v = fc.get(m, {}).get(n, {}).get(t)
                if v and v[0] is not None:
                    s += v[0] * wm; tot += wm
            if tot >= 0.75:
                out[n][d].append(s / tot)
    return out


def main():
    stations = sb.discover()[: int(os.environ.get("MAX_STATIONS", 6))]
    rows = []      # {stn, n, hi_err, lo_err}
    sampling = {}
    for cid, label, lat, lon, dist in stations:
        print("Station", cid, label, dist, "km", file=sys.stderr)
        try:
            ot, _ = sm.observations(cid)
            od = daily_obs(cid)
        except Exception as e:
            print("  obs failed", e, file=sys.stderr); continue
        if len(ot) < 4000 or len(od) < 200:
            print(f"  only {len(ot)} hours / {len(od)} days, skipping", file=sys.stderr); continue
        by_day = defaultdict(list)
        for t, v in ot.items():
            by_day[sm.lst_day(t)].append(v)
        hi_gap, lo_gap = sb.Acc(), sb.Acc()
        for d, v in by_day.items():
            if len(v) >= 22 and d in od:
                hi_gap.add(max(v) - od[d][0]); lo_gap.add(min(v) - od[d][1])
        sampling[label] = {"km": dist, "days": hi_gap.n, "high": hi_gap.bias(), "low": lo_gap.bias()}
        fc = sm.forecasts(lat, lon, cid)
        for n, days in blend_by_day(fc).items():
            for d, v in days.items():
                if len(v) >= 23 and d in od and sm.START <= d <= sm.END:
                    rows.append({"stn": label, "n": n, "hi": max(v) - od[d][0], "lo": min(v) - od[d][1]})

    print("\n## Sampling: warmest/coldest hourly reading minus recorded daily high/low (°C)")
    for k, v in sampling.items():
        print(f"  {k:<28} {v['km']:>5} km  {v['days']} days  high {v['high']:+.2f}  low {v['low']:+.2f}")

    def mae(xs): return sum(abs(x) for x in xs) / len(xs) if xs else float("nan")
    def mean(xs): return sum(xs) / len(xs) if xs else float("nan")
    names = sorted({r["stn"] for r in rows})
    report = {"sampling": sampling, "leads": {}}
    print("\n## App high/low vs recorded: bias and MAE by lead day, and with a held-out-station fix")
    for n in range(6):
        sub = [r for r in rows if r["n"] == n]
        if not sub:
            continue
        hi_b, lo_b = mean([r["hi"] for r in sub]), mean([r["lo"] for r in sub])
        fixed_hi, fixed_lo, half_hi, half_lo = [], [], [], []
        per_stn = {}
        for s in names:
            tr = [r for r in sub if r["stn"] != s]
            te = [r for r in sub if r["stn"] == s]
            if not tr or not te:
                continue
            ch, cl = mean([r["hi"] for r in tr]), mean([r["lo"] for r in tr])
            fixed_hi += [r["hi"] - ch for r in te]; fixed_lo += [r["lo"] - cl for r in te]
            half_hi += [r["hi"] - ch / 2 for r in te]; half_lo += [r["lo"] - cl / 2 for r in te]
            per_stn[s] = {"hi_bias": round(mean([r["hi"] for r in te]), 2),
                          "lo_bias": round(mean([r["lo"] for r in te]), 2),
                          "hi_mae": round(mae([r["hi"] for r in te]), 2),
                          "hi_mae_fixed": round(mae([r["hi"] - ch for r in te]), 2),
                          "lo_mae": round(mae([r["lo"] for r in te]), 2),
                          "lo_mae_fixed": round(mae([r["lo"] - cl for r in te]), 2)}
        rep = {"days": len(sub), "hi_bias": round(hi_b, 2), "lo_bias": round(lo_b, 2),
               "hi_mae": round(mae([r["hi"] for r in sub]), 3), "hi_mae_fixed": round(mae(fixed_hi), 3),
               "hi_mae_half": round(mae(half_hi), 3),
               "lo_mae": round(mae([r["lo"] for r in sub]), 3), "lo_mae_fixed": round(mae(fixed_lo), 3),
               "lo_mae_half": round(mae(half_lo), 3), "stations": per_stn}
        report["leads"][n] = rep
        print(f"  d{n} {len(sub):>5} days  high bias {hi_b:+.2f} MAE {rep['hi_mae']:.2f} -> fixed {rep['hi_mae_fixed']:.2f}"
              f" / half {rep['hi_mae_half']:.2f}   low bias {lo_b:+.2f} MAE {rep['lo_mae']:.2f} -> fixed"
              f" {rep['lo_mae_fixed']:.2f} / half {rep['lo_mae_half']:.2f}")
        for s, v in per_stn.items():
            print(f"      {s:<26} high {v['hi_bias']:+.2f} ({v['hi_mae']:.2f}->{v['hi_mae_fixed']:.2f})"
                  f"  low {v['lo_bias']:+.2f} ({v['lo_mae']:.2f}->{v['lo_mae_fixed']:.2f})")
    with open("extremes-results.json", "w") as f:
        json.dump(report, f, indent=1, default=str)


if __name__ == "__main__":
    main()
