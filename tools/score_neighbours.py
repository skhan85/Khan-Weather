#!/usr/bin/env python3
"""Can a weather station 10-80 km away make "now" more accurate where there is none closer?

Today the app only takes a station's temperature when it is within 10 km; farther out it shows
the model blend for the spot and ignores the station. A station 30 km away can't stand in for the
spot (lake, hills, city), but how wrong the models are *right now* is often shared over a wide
area: cloud the models missed, a front running early, a cold pool after a clear night. So the
idea scored here is to correct the spot's forecast by part of the error the models are making at
nearby stations:

    spot now = model at spot + k(distance) * (station reading - model at the station)

and to let that correction fade over the next hours, as the app's nudge does.

Scored at about 90 airports in 35 metro areas on six continents, each one in turn treated as the
"spot" and the other airports of its area (8-80 km away) as its neighbours:

- Observations: hourly METARs, Iowa Environmental Mesonet archive (tools/score_regions.py).
- Forecasts: Open-Meteo Single Runs (from April 2026), the mean of six global models, the app
  opening at run + 5 h; every 4th day, alternating 00 and 12 UTC runs.
- k is fitted per distance band on every region except the one being scored (held out by
  region), so nothing is tuned to any one place.

Prints MAE for: the model alone, the nearest neighbour's raw reading, and the corrected value,
by region, distance band and lead hour.

  python3 score_neighbours.py
"""
import json, math, os, sys, time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_regions as sr  # noqa: E402

START = date.fromisoformat(os.environ.get("NB_START", "2026-04-04"))
END = date.fromisoformat(os.environ.get("NB_END", "2026-11-24"))
EVERY = int(os.environ.get("NB_EVERY", "4"))
ISSUE_DELAY = 5
LEADS = list(range(0, 13))
MODELS = ["gfs_seamless", "ecmwf_ifs025", "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless",
          "gem_seamless"]
BANDS = [(8, 20), (20, 35), (35, 50), (50, 80)]
KS = [i / 20 for i in range(0, 21)]
DECAYS = [3, 6, 9, 12, 24]

# Metro areas: airports a few tens of km apart. Each one is scored with the others as neighbours.
GROUPS = {
    "na_east": [
        ["CYYZ", "CYTZ", "CYKZ", "CYHM", "CYOO"],      # Toronto
        ["CYUL", "CYHU", "CYMX"],                      # Montreal
        ["CYOW", "CYND", "CYRP"],                      # Ottawa
        ["KBOS", "KBED", "KOWD", "KBVY"],              # Boston
        ["KORD", "KMDW", "KPWK", "KDPA", "KGYY"],      # Chicago
        ["KDCA", "KIAD", "KADW", "KBWI"],              # Washington
        ["KATL", "KPDK", "KFTY", "KMGE"],              # Atlanta
        ["KDFW", "KDAL", "KAFW", "KADS", "KFTW"],      # Dallas
        ["KMIA", "KFLL", "KTMB", "KOPF"],              # Miami
        ["KMSP", "KFCM", "KSTP", "KANE"],              # Minneapolis
        ["KJFK", "KLGA", "KEWR", "KTEB", "KHPN"],      # New York
    ],
    "na_west": [
        ["CYVR", "CZBB", "CYXX", "CYNJ"],              # Vancouver
        ["CYYC", "CYBW"],                              # Calgary
        ["CYEG", "CYXD", "CYED"],                      # Edmonton
        ["KSEA", "KPAE", "KRNT", "KTIW"],              # Seattle
        ["KSFO", "KOAK", "KSJC", "KHWD", "KPAO"],      # San Francisco Bay
        ["KLAX", "KSMO", "KLGB", "KBUR", "KVNY"],      # Los Angeles
        ["KPHX", "KCHD", "KDVT", "KIWA", "KGYR"],      # Phoenix
        ["KDEN", "KAPA", "KBJC", "KFTG"],              # Denver
        ["KSLC", "KOGD", "KPVU"],                      # Salt Lake City
    ],
    "europe": [
        ["EGLL", "EGLC", "EGKK", "EGSS", "EGGW"],      # London
        ["EGCC", "EGGP", "EGNM"],                      # Manchester
        ["LFPG", "LFPO", "LFPB"],                      # Paris
        ["EDDF", "ETOU", "EDFE"],                      # Frankfurt
        ["EHAM", "EHRD", "EHLE"],                      # Amsterdam
        ["LEMD", "LETO", "LEGT", "LECU"],              # Madrid
        ["LIRF", "LIRA", "LIRU"],                      # Rome
        ["ESSA", "ESSB"],                              # Stockholm
        ["LTFM", "LTBA", "LTFJ"],                      # Istanbul
        ["EDDM", "ETSA", "EDMO"],                      # Munich
    ],
    "sw_asia": [
        ["OMDB", "OMDW", "OMSJ"],                      # Dubai
        ["OTHH", "OTBD"],                              # Doha
    ],
    "east_asia": [
        ["RJTT", "RJAA", "RJTF", "RJTY"],              # Tokyo
        ["RJBB", "RJOO", "RJBE"],                      # Osaka
        ["RKSI", "RKSS", "RKSO"],                      # Seoul
        ["RCTP", "RCSS"],                              # Taipei
    ],
    "oceania": [
        ["YSSY", "YSBK", "YSRI"],                      # Sydney
        ["YMML", "YMEN", "YMMB", "YMAV"],              # Melbourne
        ["YBBN", "YBAF", "YAMB"],                      # Brisbane
        ["YPPH", "YPJT", "YPEA"],                      # Perth
    ],
}


def km(a, b):
    r = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(min(1, math.sqrt(h)))


def band_of(d):
    return next((i for i, (a, b) in enumerate(BANDS) if a <= d < b), None)


def mean_series(series):
    """{time: mean of the models present} where at least 4 are."""
    out = {}
    times = set().union(*[set(v) for v in series.values()]) if series else set()
    for t in times:
        v = [s[t] for s in series.values() if t in s]
        if len(v) >= 4:
            out[t] = sum(v) / len(v)
    return out


def main():
    sr.END = END
    stations = {}
    for region, groups in GROUPS.items():
        for gi, g in enumerate(groups):
            for icao in g:
                obs, lat, lon = sr.metars(icao)
                if len(obs) < 1500 or lat is None:
                    print(f"{icao}: only {len(obs)} hourly reports, skipped", file=sys.stderr, flush=True)
                    continue
                stations[icao] = {"region": region, "group": (region, gi), "lat": lat, "lon": lon, "obs": obs}
    print(f"{len(stations)} airports with data", file=sys.stderr, flush=True)
    if os.environ.get("NB_STAGE") == "obs":
        return

    runs = []
    d, k = START, 0
    while d <= END:
        runs.append(datetime(d.year, d.month, d.day, 0 if k % 2 == 0 else 12))
        d += timedelta(days=EVERY)
        k += 1

    # model[icao][run] = {time: mean forecast}
    # Open-Meteo's single-runs archive is slow from GitHub's runners (TLS handshakes time out and
    # are retried), so downloads stop after NB_FETCH_MINUTES and only airports with forecasts are
    # scored. Airports are taken round-robin across regions so every region gets some, and the
    # cache (restored between runs) makes a re-run pick up where this one stopped.
    t_stop = time.time() + 60 * float(os.environ.get("NB_FETCH_MINUTES", "200"))
    by_reg = defaultdict(list)
    for icao, st in stations.items():
        by_reg[st["region"]].append(icao)
    order = []
    while any(by_reg.values()):
        for r in list(by_reg):
            if by_reg[r]:
                order.append(by_reg[r].pop(0))
    model = defaultdict(dict)
    for n, icao in enumerate(order):
        st = stations[icao]
        cached = all(os.path.exists(os.path.join(sr.CACHE, f"sr-{icao}-{run:%Y%m%d%H}-2-{'_'.join(MODELS)}.json"))
                     for run in runs)
        if not cached and time.time() > t_stop:
            continue

        def load(run, st=st, icao=icao):
            return run, mean_series(sr.single_run(st["lat"], st["lon"], MODELS, run, icao, 2))
        with ThreadPoolExecutor(3) as pool:
            for run, s in pool.map(load, runs):
                model[icao][run] = s
        print(f"  {n + 1}/{len(order)} {icao}: {sum(1 for s in model[icao].values() if s)} runs",
              file=sys.stderr, flush=True)
    for icao in list(stations):
        if not any(model[icao].values()):
            del stations[icao]
    print(f"{len(stations)} airports with forecasts", file=sys.stderr, flush=True)

    # cases: one per (target, run, lead) with the target's truth and model value, and its
    # neighbours' error at app-open time.
    cases = []
    for icao, st in stations.items():
        nbrs = []
        for other, so in stations.items():
            if other == icao or so["group"] != st["group"]:
                continue
            dist = km((st["lat"], st["lon"]), (so["lat"], so["lon"]))
            if band_of(dist) is not None:
                nbrs.append((dist, other))
        nbrs.sort()
        if not nbrs:
            continue
        for run in runs:
            mt = model[icao].get(run) or {}
            issue = run + timedelta(hours=ISSUE_DELAY)
            ti = issue.strftime("%Y-%m-%dT%H:00")
            errs = []
            for dist, other in nbrs:
                mo = model[other].get(run) or {}
                o = stations[other]["obs"].get(ti)
                if o is not None and ti in mo:
                    errs.append((dist, o - mo[ti], o))
            if not errs:
                continue
            for lead in LEADS:
                t = (issue + timedelta(hours=lead)).strftime("%Y-%m-%dT%H:00")
                truth = st["obs"].get(t)
                if truth is None or t not in mt:
                    continue
                cases.append({"icao": icao, "region": st["region"], "lead": lead, "truth": truth,
                              "model": mt[t], "errs": errs})
    print(f"{len(cases)} cases", file=sys.stderr, flush=True)

    def predict(c, kband, decay, use="nearest"):
        """Corrected value. kband[i] = share of the neighbour error taken in band i."""
        share = max(0.0, 1 - c["lead"] / decay)
        if use == "nearest":
            dist, e, _ = c["errs"][0]
            return c["model"] + kband[band_of(dist)] * e * share
        # inverse-distance weighted, each neighbour's error shrunk by its band's k
        w = [(1 / dist ** 2, kband[band_of(dist)] * e) for dist, e, _ in c["errs"]]
        s = sum(a for a, _ in w)
        return c["model"] + sum(a * b for a, b in w) / s * share

    def fit_k(train, use):
        """Best k per band at lead 0 (nearest neighbour's band decides)."""
        kb = []
        for bi in range(len(BANDS)):
            rows = [c for c in train if c["lead"] == 0 and band_of(c["errs"][0][0]) == bi]
            if len(rows) < 200:
                kb.append(0.0)
                continue
            best = min(KS, key=lambda k: sum(abs(predict(c, [k] * len(BANDS), 1e9, use) - c["truth"])
                                             for c in rows))
            kb.append(best)
        return kb

    def mae(rows, f):
        return sum(abs(f(c) - c["truth"]) for c in rows) / len(rows) if rows else float("nan")

    regions = sorted({c["region"] for c in cases})
    report = {"period": [START.isoformat(), END.isoformat()], "every_days": EVERY, "regions": {}}
    held = {}
    for use in ("nearest", "idw"):
        for r in regions:
            held[(use, r)] = fit_k([c for c in cases if c["region"] != r], use)
    all_k = {use: fit_k(cases, use) for use in ("nearest", "idw")}
    print("\nk per band fitted on all regions:", {u: dict(zip([f"{a}-{b}km" for a, b in BANDS], v))
                                                  for u, v in all_k.items()})
    report["k_all"] = all_k

    # decay: pick on all regions with held-out k
    def held_pred(c, decay, use):
        return predict(c, held[(use, c["region"])], decay, use)

    print("\n## Decay of the correction over lead hours (held-out k, all regions)")
    dec_scores = {}
    for use in ("nearest", "idw"):
        for D in DECAYS:
            rows = [c for c in cases if c["lead"] >= 1]
            dec_scores[(use, D)] = mae(rows, lambda c: held_pred(c, D, use))
            print(f"  {use:<8} fade over {D:>2} h: MAE leads 1-12 {dec_scores[(use, D)]:.3f}")
    print(f"  model only:            MAE leads 1-12 {mae([c for c in cases if c['lead'] >= 1], lambda c: c['model']):.3f}")
    best_use, best_D = min(dec_scores, key=dec_scores.get)
    report["best"] = {"method": best_use, "fade_hours": best_D}
    print(f"best: {best_use}, fade over {best_D} h")

    print("\n## Now (lead 0), held out by region")
    print(f"  {'region':<10} {'n':>6} {'model':>7} {'nearest raw':>12} {'corrected':>10} {'idw':>7}  k(held out)")
    for r in regions + ["ALL"]:
        rows = [c for c in cases if c["lead"] == 0 and (r == "ALL" or c["region"] == r)]
        if not rows:
            continue
        m = mae(rows, lambda c: c["model"])
        raw = mae(rows, lambda c: c["errs"][0][2])
        cor = mae(rows, lambda c: held_pred(c, best_D, "nearest"))
        idw = mae(rows, lambda c: held_pred(c, best_D, "idw"))
        ks = held.get(("nearest", r), all_k["nearest"])
        print(f"  {r:<10} {len(rows):>6} {m:>7.3f} {raw:>12.3f} {cor:>10.3f} {idw:>7.3f}  {ks}")
        report["regions"][r] = {"n": len(rows), "model": m, "nearest_raw": raw, "corrected": cor, "idw": idw}

    print("\n## Now (lead 0) by distance to the nearest neighbour, held out by region")
    for bi, (a, b) in enumerate(BANDS):
        rows = [c for c in cases if c["lead"] == 0 and band_of(c["errs"][0][0]) == bi]
        if not rows:
            continue
        print(f"  {a}-{b} km n={len(rows):>6}: model {mae(rows, lambda c: c['model']):.3f}  "
              f"raw {mae(rows, lambda c: c['errs'][0][2]):.3f}  "
              f"corrected {mae(rows, lambda c: held_pred(c, best_D, best_use)):.3f}")

    print(f"\n## By lead hour ({best_use}, fade {best_D} h, held out by region)")
    for lead in LEADS:
        rows = [c for c in cases if c["lead"] == lead]
        print(f"  +{lead:>2} h n={len(rows):>6}: model {mae(rows, lambda c: c['model']):.3f}  "
              f"corrected {mae(rows, lambda c: held_pred(c, best_D, best_use)):.3f}")

    print("\n## By airport (lead 0): model -> corrected")
    worse = 0
    for icao in sorted({c["icao"] for c in cases}):
        rows = [c for c in cases if c["lead"] == 0 and c["icao"] == icao]
        m, cor = mae(rows, lambda c: c["model"]), mae(rows, lambda c: held_pred(c, best_D, best_use))
        worse += cor > m
        print(f"  {icao} {stations[icao]['region']:<10} n={len(rows):>4} nearest {rows[0]['errs'][0][0]:5.1f} km: "
              f"{m:.2f} -> {cor:.2f}{'  WORSE' if cor > m else ''}")
    print(f"airports made worse: {worse}")
    with open("neighbour-report.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
