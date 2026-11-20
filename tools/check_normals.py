#!/usr/bin/env python3
"""Are Open-Meteo's historical normals (ERA5, what the app uses for "warmer than usual") close to
Environment Canada's real station records around Milton?

For each ECCC station near Milton with daily data through 1991-2020, compares the 1991-2020
average daily high and low by month: station record vs Open-Meteo's archive at the station's spot.
Also prints the app's normal for Milton on a few dates.
"""
import math, sys, urllib.parse
from collections import defaultdict
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_models as sm  # noqa: E402

MILTON = (43.5183, -79.8774)
Y0, Y1 = 1991, 2020


def km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (*a, *b))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 12742 * math.asin(math.sqrt(h))


def stations():
    q = {"f": "json", "bbox": "-80.6,43.1,-79.2,43.9", "limit": 1000}
    d = sm.get_json("https://api.weather.gc.ca/collections/climate-stations/items?" + urllib.parse.urlencode(q),
                    "normals-stations.json")
    out = []
    for f in d.get("features", []):
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"][:2]
        first = str(p.get("DLY_FIRST_DATE") or "")[:4]
        last = str(p.get("DLY_LAST_DATE") or "")[:4]
        if not first or not last or first > "1993" or last < "2018":
            continue
        out.append((p["CLIMATE_IDENTIFIER"], p.get("STATION_NAME"), lat, lon, round(km(MILTON, (lat, lon)), 1)))
    out.sort(key=lambda s: s[4])
    return out[:8]


def station_means(cid):
    rng = f"{Y0}-01-01T00:00:00/{Y1}-12-31T23:59:59"
    feats = sm.ogc_all("climate-daily", {"CLIMATE_IDENTIFIER": cid, "datetime": rng}, f"normals-dly-{cid}")
    hi, lo = defaultdict(list), defaultdict(list)
    for f in feats:
        p = f["properties"]
        m = int(p["LOCAL_MONTH"])
        if p.get("MAX_TEMPERATURE") is not None:
            hi[m].append(float(p["MAX_TEMPERATURE"]))
        if p.get("MIN_TEMPERATURE") is not None:
            lo[m].append(float(p["MIN_TEMPERATURE"]))
    return hi, lo


def era5(lat, lon, tag):
    q = {"latitude": round(lat, 4), "longitude": round(lon, 4), "start_date": f"{Y0}-01-01",
         "end_date": f"{Y1}-12-31", "daily": "temperature_2m_max,temperature_2m_min", "timezone": "America/Toronto"}
    d = sm.get_json("https://archive-api.open-meteo.com/v1/archive?" + urllib.parse.urlencode(q), f"normals-era5-{tag}.json")
    dl = d["daily"]
    hi, lo = defaultdict(list), defaultdict(list)
    for t, a, b in zip(dl["time"], dl["temperature_2m_max"], dl["temperature_2m_min"]):
        m = int(t[5:7])
        if a is not None:
            hi[m].append(a)
        if b is not None:
            lo[m].append(b)
    return hi, lo, d.get("elevation")


def mean(v):
    return sum(v) / len(v) if v else None


def main():
    found = stations()
    print("Stations:", *found, sep="\n  ")
    all_hi, all_lo = [], []
    for cid, name, lat, lon, dist in found:
        try:
            shi, slo = station_means(cid)
            ehi, elo, elev = era5(lat, lon, cid)
        except Exception as e:  # noqa: BLE001
            print(name, "failed", e)
            continue
        n = sum(len(v) for v in shi.values())
        if n < 300 * 25:
            print(f"\n{name} ({cid}): only {n} days, skipped")
            continue
        print(f"\n{name} ({cid}), {dist} km from Milton, {n} days. Open-Meteo minus station, by month:")
        row_hi, row_lo = [], []
        for m in range(1, 13):
            dh = mean(ehi[m]) - mean(shi[m]) if shi[m] else None
            dl = mean(elo[m]) - mean(slo[m]) if slo[m] else None
            row_hi.append(dh); row_lo.append(dl)
        fmt = lambda r: " ".join("  -- " if x is None else f"{x:+5.1f}" for x in r)  # noqa: E731
        print("  highs:", fmt(row_hi))
        print("  lows: ", fmt(row_lo))
        all_hi += [x for x in row_hi if x is not None]
        all_lo += [x for x in row_lo if x is not None]
        print(f"  mean bias highs {mean(row_hi and [x for x in row_hi if x is not None]):+.2f}, "
              f"lows {mean([x for x in row_lo if x is not None]):+.2f}")
    if all_hi:
        print(f"\nAll stations, all months: highs {mean(all_hi):+.2f} (abs {mean([abs(x) for x in all_hi]):.2f}), "
              f"lows {mean(all_lo):+.2f} (abs {mean([abs(x) for x in all_lo]):.2f})")
    hi, lo, elev = era5(*MILTON, "milton")
    print(f"\nMilton (Open-Meteo elevation {elev} m), 1991-2020 monthly normal high/low:")
    for m in range(1, 13):
        print(f"  {m:2d}: {mean(hi[m]):5.1f} / {mean(lo[m]):5.1f}")


if __name__ == "__main__":
    main()
