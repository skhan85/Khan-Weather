#!/usr/bin/env python3
"""When the radar is dry, how well can other clues tell that it is drizzling or raining lightly?

Radar misses drizzle (27 Nov 2026 in Milton: drizzle all morning, card "Overcast"). The app now
has three clues besides the radar (Forecast.drizzlingRadarCantSee):

  A. an airport or station within 40 km reports drizzle, and the air here is damp under cloud;
  B. at least two airports or stations within 40 km report rain or drizzle (widespread light rain);
  C. most of the blend's models put measurable rain (>= 0.2 mm) in the current hour, with damp
     air under cloud.

This scores them at clusters of airports around the world (each airport is "here", the others
in its cluster within 40 km are its neighbours):

- Observations: hourly METARs from the Iowa Environmental Mesonet archive (present weather,
  humidity, cloud). "Wet" = the METAR reports DZ, RA, SN, SG, PL or UP.
- Models: Open-Meteo's Historical Forecast archive (the first hours of each run strung together,
  i.e. what the app sees for "now"), hourly precipitation of the core blend models.

Only hours that are candidates for the rule are counted: -3..15 °C, cloud BKN/OVC/VV or fog, and
humidity at or above the threshold. Precision is the share of hours a clue fires that really were
wet; recall the share of wet candidate hours it catches. There's no radar archive here, so the
"radar is dry" part can't be checked: these numbers are for the clue alone.

  python3 score_drizzle.py
"""
import csv, io, json, math, os, sys, time, urllib.error, urllib.parse, urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta

CACHE = "verify-cache"
START = date.fromisoformat(os.environ.get("DZ_START", "2025-10-01"))
END = date.fromisoformat(os.environ.get("DZ_END", "2026-11-20"))
MODELS = ["gem_seamless", "gfs_seamless", "ecmwf_ifs025", "icon_seamless", "ukmo_seamless",
          "ecmwf_aifs025_single"]
WET_MM = 0.2          # ModelBlend.wetHourMm
NEAR_KM = 40          # Observation.drizzleReachKm
RH_LEVELS = [85, 88, 90, 93, 95]
SHARE_LEVELS = [0.34, 0.5, 0.67]

# Clusters of airports a few tens of km apart, in places where drizzle and light rain are common.
CLUSTERS = {
    "Toronto-Hamilton": ["CYYZ", "CYHM", "CYTZ", "CYKF", "CYOO"],
    "Montreal": ["CYUL", "CYHU", "CYMX"],
    "Ottawa": ["CYOW", "CYRO"],
    "Vancouver": ["CYVR", "CYXX", "CZBB", "CYNJ", "CYPK"],
    "Halifax": ["CYHZ", "CYAW"],
    "Calgary": ["CYYC", "CYBW"],
    "Seattle": ["KSEA", "KBFI", "KRNT", "KPAE"],
    "Boston": ["KBOS", "KBED", "KOWD", "KBVY"],
    "New York": ["KJFK", "KLGA", "KEWR", "KTEB", "KHPN"],
    "Chicago": ["KORD", "KMDW", "KPWK", "KDPA"],
    "San Francisco": ["KSFO", "KOAK", "KSJC", "KHWD"],
    "London": ["EGLL", "EGLC", "EGKK", "EGSS", "EGGW", "EGWU"],
    "Manchester": ["EGCC", "EGNR", "EGNM"],
    "Dublin": ["EIDW", "EIME"],
    "Paris": ["LFPG", "LFPO", "LFPB", "LFPV"],
    "Amsterdam": ["EHAM", "EHRD", "EHLE"],
    "Frankfurt": ["EDDF", "EDFE", "ETOU"],
    "Melbourne": ["YMML", "YMEN", "YMMB", "YMAV"],
    "Sydney": ["YSSY", "YSBK", "YSRI"],
    "Tokyo": ["RJTT", "RJTF", "RJTY"],
}


def fetch(url, name, kind="json"):
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        with open(path) as f:
            body = f.read()
        return body if kind == "text" else json.loads(body)
    os.makedirs(CACHE, exist_ok=True)
    for attempt in range(4):
        try:
            if "open-meteo" in url:
                time.sleep(1.0)
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read().decode()
            with open(path, "w") as f:
                f.write(body)
            return body if kind == "text" else json.loads(body)
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:200]
            print("  HTTP", e.code, msg[:160], url[-120:], file=sys.stderr, flush=True)
            if e.code == 400:
                return None
            time.sleep(60 * (attempt + 1) if e.code == 429 else 10 * (attempt + 1))
        except Exception as e:
            print("  retry", attempt, name, e, file=sys.stderr, flush=True)
            time.sleep(10 * (attempt + 1))
    return None


def iem_id(icao):
    # IEM keeps US airports under their 3-letter ids.
    return icao[1:] if icao.startswith("K") and len(icao) == 4 else icao


WET_CODES = ("DZ", "RA", "SN", "SG", "PL", "UP")


def metars(icao):
    """({hour: {t, rh, cloudy, wet, drizzle}}, lat, lon), the report nearest each hour (±20 min)."""
    q = {"station": iem_id(icao), "data": ["tmpc", "relh", "skyc1", "skyc2", "skyc3", "wxcodes"],
         "year1": START.year, "month1": START.month, "day1": START.day,
         "year2": END.year, "month2": END.month, "day2": END.day, "tz": "Etc/UTC",
         "format": "onlycomma", "latlon": "yes", "missing": "empty", "report_type": [3, 4]}
    url = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?" + urllib.parse.urlencode(q, doseq=True)
    body = fetch(url, f"dz-iem-{icao}-{START}-{END}.csv", kind="text")
    if not body:
        return {}, None, None
    best, lat, lon = {}, None, None
    for row in csv.DictReader(io.StringIO(body)):
        try:
            ts = datetime.strptime(row["valid"], "%Y-%m-%d %H:%M")
            lat, lon = float(row["lat"]), float(row["lon"])
            t = float(row["tmpc"]) if row.get("tmpc") else None
            rh = float(row["relh"]) if row.get("relh") else None
        except (ValueError, KeyError):
            continue
        if t is None or rh is None:
            continue
        hour = (ts + timedelta(minutes=30)).replace(minute=0)
        off = abs((ts - hour).total_seconds()) / 60
        if off > 20:
            continue
        wx = (row.get("wxcodes") or "").upper()
        covers = {(row.get(k) or "").upper() for k in ("skyc1", "skyc2", "skyc3")}
        cloudy = bool(covers & {"BKN", "OVC", "VV"}) or "FG" in wx or "BR" in wx
        wet = any(c in wx for c in WET_CODES)
        k = hour.strftime("%Y-%m-%dT%H:00")
        if k not in best or off < best[k][0]:
            best[k] = (off, {"t": t, "rh": rh, "cloudy": cloudy, "wet": wet,
                             "drizzle": "DZ" in wx and "TS" not in wx})
    return {k: v for k, (_, v) in best.items()}, lat, lon


def months():
    a = START.replace(day=1)
    while a <= END:
        b = (a.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
        yield max(a, START), min(b, END)
        a = b + timedelta(days=1)


def model_precip(lat, lon, tag):
    """{hour: {model: mm}} from the historical forecast archive."""
    out = defaultdict(dict)
    for a, b in months():
        q = {"latitude": round(lat, 3), "longitude": round(lon, 3), "hourly": "precipitation",
             "models": ",".join(MODELS), "timezone": "GMT",
             "start_date": a.isoformat(), "end_date": b.isoformat()}
        url = "https://historical-forecast-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
        d = fetch(url, f"dz-hf-{tag}-{a}.json")
        if not d:
            continue
        h = d.get("hourly", {})
        for m in MODELS:
            for t, v in zip(h.get("time", []), h.get(f"precipitation_{m}") or []):
                if v is not None:
                    out[t][m] = v
    return out


def km(a, b):
    r = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(min(1, math.sqrt(h)))


class Tally:
    def __init__(self):
        self.fire = 0
        self.hit = 0
        self.dz_hit = 0

    def add(self, fired, wet, drizzle):
        if fired:
            self.fire += 1
            self.hit += wet
            self.dz_hit += drizzle


def main():
    obs, pos = {}, {}
    for name, ids in CLUSTERS.items():
        for icao in ids:
            o, lat, lon = metars(icao)
            if len(o) > 500 and lat is not None:
                obs[icao], pos[icao] = o, (lat, lon)
            else:
                print(f"  {icao}: {len(o)} hours, skipped", file=sys.stderr)
    print(f"{len(obs)} airports with METARs, {START}..{END}", flush=True)
    models = {}
    for icao, (lat, lon) in pos.items():
        models[icao] = model_precip(lat, lon, icao)

    # tallies[rh][clue] ; base[rh] = (candidate hours, wet, drizzle)
    tallies = defaultdict(lambda: defaultdict(Tally))
    base = defaultdict(lambda: [0, 0, 0])
    by_cluster = defaultdict(lambda: defaultdict(Tally))
    base_cluster = defaultdict(lambda: [0, 0])
    for cname, ids in CLUSTERS.items():
        for icao in ids:
            if icao not in obs:
                continue
            nbrs = [n for n in ids if n != icao and n in obs and km(pos[icao], pos[n]) <= NEAR_KM]
            for hour, o in obs[icao].items():
                if not (-3 < o["t"] < 15) or not o["cloudy"]:
                    continue
                mp = models[icao].get(hour, {})
                share = (sum(v >= WET_MM for v in mp.values()) / len(mp)) if len(mp) >= 3 else None
                nb = [obs[n].get(hour) for n in nbrs]
                nb = [x for x in nb if x]
                nb_dz = any(x["drizzle"] for x in nb)
                nb_wet = sum(x["wet"] for x in nb)
                for rh in RH_LEVELS:
                    if o["rh"] < rh:
                        continue
                    b = base[rh]
                    b[0] += 1; b[1] += o["wet"]; b[2] += o["drizzle"]
                    t = tallies[rh]
                    t["A: neighbour drizzle"].add(nb_dz, o["wet"], o["drizzle"])
                    t["B: >=2 neighbours wet"].add(nb_wet >= 2, o["wet"], o["drizzle"])
                    t["B1: >=1 neighbour wet"].add(nb_wet >= 1, o["wet"], o["drizzle"])
                    for s in SHARE_LEVELS:
                        t[f"C: models wet >= {s:.2f}"].add(share is not None and share >= s, o["wet"], o["drizzle"])
                    t["A or B or C(.50)"].add(nb_dz or nb_wet >= 2 or (share or 0) >= 0.5, o["wet"], o["drizzle"])
                    if rh == 90:
                        bc = base_cluster[cname]
                        bc[0] += 1; bc[1] += o["wet"]
                        by_cluster[cname]["C .50"].add((share or 0) >= 0.5, o["wet"], o["drizzle"])
                        by_cluster[cname]["B >=2"].add(nb_wet >= 2, o["wet"], o["drizzle"])

    # How far a station's rain reaches: one neighbour reporting rain, damp cloudy air (RH >= 90%,
    # above 1 °C) here. Precision = share of those hours wet here, by distance to that neighbour.
    # "no model vote" = the same, in hours when fewer than half the models had rain (the app's
    # model-vote rule wouldn't fire, as in Mississauga on 27 Nov).
    BUCKETS = [(0, 10), (10, 15), (15, 20), (20, 25), (25, 30), (30, 40)]
    dist = defaultdict(lambda: [0, 0, 0, 0])
    for cname, ids in CLUSTERS.items():
        for icao in ids:
            if icao not in obs:
                continue
            for n in ids:
                if n == icao or n not in obs:
                    continue
                d = km(pos[icao], pos[n])
                bk = next((b for b in BUCKETS if b[0] <= d < b[1]), None)
                if bk is None:
                    continue
                for hour, o in obs[icao].items():
                    if not (1 < o["t"] < 15) or not o["cloudy"] or o["rh"] < 90:
                        continue
                    x = obs[n].get(hour)
                    if not x or not x["wet"]:
                        continue
                    mp = models[icao].get(hour, {})
                    share = (sum(v >= WET_MM for v in mp.values()) / len(mp)) if len(mp) >= 3 else 0
                    c = dist[bk]
                    c[0] += 1; c[1] += o["wet"]
                    if share < 0.5:
                        c[2] += 1; c[3] += o["wet"]
    print("\nOne neighbour reports rain, RH >= 90% cloudy >1 °C here: wet here, by distance")
    print(f"  {'km':8} {'hours':>7} {'precision':>9} | no model vote: {'hours':>7} {'precision':>9}")
    for bk in BUCKETS:
        c = dist[bk]
        print(f"  {bk[0]:>2}-{bk[1]:<5} {c[0]:7d} {c[1] / max(c[0], 1):9.0%} |                {c[2]:7d} {c[3] / max(c[2], 1):9.0%}")

    # Within 25 km, models' vote below half: does damper air or a trace in any model help?
    # base = all such hours (no model vote) here, whether or not a neighbour reported rain.
    var = defaultdict(lambda: [0, 0])
    for cname, ids in CLUSTERS.items():
        for icao in ids:
            if icao not in obs:
                continue
            nb25 = [n for n in ids if n != icao and n in obs and km(pos[icao], pos[n]) < 25]
            for hour, o in obs[icao].items():
                if not (1 < o["t"] < 15) or not o["cloudy"] or o["rh"] < 90:
                    continue
                mp = models[icao].get(hour, {})
                share = (sum(v >= WET_MM for v in mp.values()) / len(mp)) if len(mp) >= 3 else 0
                if share >= 0.5:
                    continue
                trace = sum(v >= 0.1 for v in mp.values())
                nbw = any(obs[n].get(hour, {}).get("wet") for n in nb25)
                for rh in (90, 93, 95):
                    if o["rh"] < rh:
                        continue
                    keys = [f"base RH>={rh}"]
                    if nbw:
                        keys.append(f"nbr<25 RH>={rh}")
                        if trace >= 1:
                            keys.append(f"nbr<25 RH>={rh} +1 model trace")
                        if trace >= 2:
                            keys.append(f"nbr<25 RH>={rh} +2 model trace")
                    for k in keys:
                        var[k][0] += 1; var[k][1] += o["wet"]
    print("\nNo model vote (<half the models >= 0.2 mm), >1 °C cloudy: wet here")
    for k in sorted(var):
        n, w = var[k]
        print(f"  {k:32} {n:7d} {w / max(n, 1):6.0%}")

    report = {}
    for rh in RH_LEVELS:
        n, w, dz = base[rh]
        print(f"\nRH >= {rh}%, cloudy, -3..15 °C: {n} hours, wet {w / max(n, 1):.0%} (drizzle {dz / max(n, 1):.0%})")
        print(f"  {'clue':26} {'fires':>7} {'precision':>9} {'recall':>7} {'drizzle':>8}")
        rep = {"hours": n, "wet": w, "drizzle": dz, "clues": {}}
        for clue, t in sorted(tallies[rh].items()):
            prec = t.hit / t.fire if t.fire else 0
            rec = t.hit / w if w else 0
            print(f"  {clue:26} {t.fire:7d} {prec:9.0%} {rec:7.0%} {t.dz_hit / max(t.fire, 1):8.0%}")
            rep["clues"][clue] = {"fires": t.fire, "precision": round(prec, 3), "recall": round(rec, 3)}
        report[str(rh)] = rep
    print("\nBy cluster, RH >= 90%: precision of C (models >= .50) and B (>=2 neighbours wet)")
    for cname, tal in by_cluster.items():
        n, w = base_cluster[cname]
        c, b = tal["C .50"], tal["B >=2"]
        print(f"  {cname:18} base {w / max(n, 1):4.0%} of {n:5d} | C {c.hit / max(c.fire, 1):4.0%} of {c.fire:5d}"
              f" | B {b.hit / max(b.fire, 1):4.0%} of {b.fire:5d}")
    with open("drizzle-report.json", "w") as f:
        json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
