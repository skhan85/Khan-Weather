#!/usr/bin/env python3
"""Khan Weather's per-place learning: score the forecast against what happened at each place the
family uses, and correct that place's own, proven errors.

Runs on the relay (Saad's VPS), hourly from cron:

    7 * * * *  cd ~/khan-weather-relay/learn && python3 learner.py run >> run.log 2>&1

and the relay answers the app's GET /v1/learned?lat=..&lon=.. with `lookup(lat, lon)`, which also
registers the place (0.1° cell, about 10 km), so every place anyone in the family opens is learned.

Each hour, for every place opened in the last 30 days:
  * Truth for temperature: an official station within 10 km (ECCC SWOB in Canada, else an airport
    METAR), or failing that the middle of at least 3 Netatmo stations within 5 km (via the relay).
    Nothing farther: a station 25 km away has its own biases (tools/score_bias.py showed a bias
    learned at one station makes others worse), so a place without local truth learns nothing.
  * Truth for rain: the ECCC radar over the place (three frames in the hour, Canada), plus rain or
    drizzle reported by a station within 15 km (radar misses drizzle), plus home rain gauges.
  * Every 3 hours: the forecast for the next 5 days, the same way the app blends it (the region
    weights in blend-regions.json, fetched from the repo), plus Open-Meteo's chance of rain.

Learning, per place, from the last 45 days (recent days count more, half-weight after ~7 days):
  * Temperature: the blend's average error by 3-hour block of the day (8 numbers, the shape the app
    already reads), shrunk toward zero while there's little data, capped at ±3°.
  * Rain: how often it really rained here when the chance said p (one multiplier on the chance).
  * Timing: whether rain here tends to come early or late (reported only; storms differ too much
    for one shift to hold).
Each correction is switched on only when it proves itself on the last 14 days, fitted each time on
data from before the forecast was made (as the app would have had it): at least 3% smaller error.
So it can't make a place worse for long, and nothing is tuned to Milton: each place earns its own.

Standard library only. Data lives next to this file (DATA_DIR): places.json, fc/, obs/, learned/.
"""
import json, math, os, statistics, sys, time, urllib.parse, urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("LEARN_DATA_DIR", os.path.join(HERE, "data"))
RELAY = os.environ.get("LEARN_RELAY", "http://172.18.0.1:8787")
REGIONS_URL = ("https://raw.githubusercontent.com/skhan85/Khan-Weather/main/"
               "Packages/WeatherCore/blend-regions.json")
UA = {"User-Agent": "KhanWeather-learner/1 (github.com/skhan85/Khan-Weather)"}

ACTIVE_DAYS = 30          # a place not opened for this long stops being learned, unless pinned
KEEP_DAYS = 45            # history used
CHECK_DAYS = 14           # held-out window that must show a gain
MIN_DAYS = 10             # history needed before anything is switched on
GAIN = 0.97               # learned error must be at most this share of the raw error
HALF_LIFE_DAYS = 7
TEMP_SHRINK_HOURS = 24    # per 3-hour block; ~8 days of data gives half the measured bias
TEMP_CAP = 3.0
POP_PRIOR = 8.0           # wet hours of prior belief that the chance is right
POP_RANGE = (0.5, 1.6)
LOCAL_KM = 10
NETATMO_KM = 5
RAIN_REPORT_KM = 15
WET_MM = 0.2              # ModelBlend.wetHourMm
FC_EVERY_H = 3
FC_DAYS = 6
MODEL_IDS = {
    "canada": "gem_seamless", "canadaHighRes": "gem_hrdps_continental", "us": "gfs_seamless",
    "usHighRes": "gfs_hrrr", "europe": "ecmwf_ifs025", "uk": "ukmo_seamless", "germany": "icon_seamless",
    "europeAI": "ecmwf_aifs025_single", "usBlend": "ncep_nbm_conus", "europeHighRes": "ecmwf_ifs",
    "france": "meteofrance_seamless", "netherlands": "knmi_seamless", "denmark": "dmi_seamless",
    "norway": "metno_seamless", "japan": "jma_seamless",
}


# ---------------------------------------------------------------- small helpers
def log(*a):
    print(datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ"), *a, flush=True)


def get_json(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def km(a_lat, a_lon, b_lat, b_lon):
    la1, lo1, la2, lo2 = map(math.radians, (a_lat, a_lon, b_lat, b_lon))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0 * math.asin(min(1.0, math.sqrt(h)))


def cell_of(lat, lon):
    """Same as the app's ModelBlend.spotKey: tenths of a degree."""
    return f"{int(round(lat * 10))},{int(round(lon * 10))}"


def cell_centre(cell):
    a, b = cell.split(",")
    return int(a) / 10, int(b) / 10


def path(*parts):
    p = os.path.join(DATA, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def load(p, default):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(p, obj):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, separators=(",", ":"))
    os.replace(tmp, p)


def append_jsonl(p, row):
    with open(p, "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def read_jsonl(p, since):
    out = []
    try:
        with open(p) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("t", 0) >= since:
                    out.append(r)
    except OSError:
        pass
    return out


def trim_jsonl(p, since):
    rows = read_jsonl(p, since)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
    os.replace(tmp, p)


def in_canada(lat, lon):
    return 41.6 <= lat <= 84 and -141 <= lon <= -52


# ---------------------------------------------------------------- the relay's side
def lookup(lat, lon, register=True, now=None):
    """What /v1/learned returns. Registers the place's cell so the hourly run learns it."""
    now = now or time.time()
    cell = cell_of(lat, lon)
    if register:
        places = load(path("places.json"), {})
        p = places.get(cell)
        # Write at most every 10 minutes per cell, so a busy relay isn't rewriting the file.
        if not p or now - p.get("last_seen", 0) > 600:
            places[cell] = dict(p or {}, first_seen=(p or {}).get("first_seen", now), last_seen=now)
            try:
                save(path("places.json"), places)
            except OSError:
                pass
    learned = load(path("learned", cell.replace(",", "_") + ".json"), None)
    if not learned:
        return {"cell": cell, "status": "learning", "temperature": {"enabled": False},
                "rain": {"enabled": False}, "days": 0}
    return learned


# ---------------------------------------------------------------- observations
def metars(lat, lon):
    d = 0.3
    bbox = f"{lat - d:.3f},{lon - d * 1.5:.3f},{lat + d:.3f},{lon + d * 1.5:.3f}"
    try:
        rows = get_json(f"https://aviationweather.gov/api/data/metar?bbox={bbox}&format=json")
    except Exception as e:
        log("  metar failed", e)
        return []
    out = []
    for m in rows or []:
        if m.get("lat") is None or m.get("lon") is None or m.get("obsTime") is None:
            continue
        out.append({"name": m.get("icaoId") or m.get("name"), "km": km(lat, lon, m["lat"], m["lon"]),
                    "t": m["obsTime"], "temp": m.get("temp"), "wx": (m.get("wxString") or "").upper()})
    return out


def swob(lat, lon, now):
    if not in_canada(lat, lon):
        return []
    since = datetime.fromtimestamp(now - 5400, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    q = {"f": "json", "bbox": f"{lon - 0.15:.3f},{lat - 0.1:.3f},{lon + 0.15:.3f},{lat + 0.1:.3f}",
         "datetime": since + "/..", "_is-minutely_obs-value": "false", "sortby": "-obs_date_tm", "limit": "80"}
    try:
        d = get_json("https://api.weather.gc.ca/collections/swob-realtime/items?" + urllib.parse.urlencode(q))
    except Exception as e:
        log("  swob failed", e)
        return []
    newest = {}
    for f in d.get("features", []):
        p, g = f.get("properties", {}), f.get("geometry", {}).get("coordinates")
        if not g or p.get("air_temp") in (None, "") or "TEST" in str(p.get("stn_nam-value", "")).upper():
            continue
        try:
            t = datetime.fromisoformat(p["obs_date_tm"].replace("Z", "+00:00")).timestamp()
            temp = float(p["air_temp"])
        except (KeyError, ValueError):
            continue
        rain = p.get("pcpn_amt_pst1hr", p.get("rnfl_amt_pst1hr"))
        key = p.get("msc_id-value") or p.get("stn_nam-value")
        if key in newest and newest[key]["t"] >= t:
            continue
        try:
            rain = float(rain) if rain not in (None, "") else None
        except ValueError:
            rain = None
        newest[key] = {"name": p.get("stn_nam-value"), "km": km(lat, lon, g[1], g[0]), "t": t,
                       "temp": temp, "rain1h": rain}
    return list(newest.values())


def netatmo(lat, lon):
    try:
        d = get_json(f"{RELAY}/v1/netatmo?lat={lat:.4f}&lon={lon:.4f}", timeout=15)
    except Exception as e:
        log("  netatmo failed", e)
        return []
    out = []
    for s in d.get("stations", []):
        if s.get("lat") is None:
            continue
        out.append({"km": km(lat, lon, s["lat"], s["lon"]), "t": s.get("observed") or 0,
                    "temp": s.get("temperature"), "rain1h": s.get("rain_60min")})
    return out


def radar_mean_rate(lat, lon, hour_end):
    """Mean of three ECCC radar frames in the hour before `hour_end` (rain mm/h or snow cm/h), or None.
    Like a model's hourly precipitation, which is what fell in the hour up to its time."""
    vals = []
    # ECCC 1 km radar frames come every 6 minutes (:00, :06 ... :54): ask for ones that exist.
    for minute in (48, 30, 12):
        t = datetime.fromtimestamp(hour_end - minute * 60, timezone.utc).strftime("%Y-%m-%dT%H:%M:00Z")
        frame = 0.0
        for layer in ("RADAR_1KM_RRAI", "RADAR_1KM_RSNO"):
            q = {"service": "WMS", "version": "1.3.0", "request": "GetFeatureInfo", "layers": layer,
                 "query_layers": layer, "crs": "EPSG:4326",
                 "bbox": f"{lat - 0.01:.4f},{lon - 0.01:.4f},{lat + 0.01:.4f},{lon + 0.01:.4f}",
                 "width": 3, "height": 3, "i": 1, "j": 1, "info_format": "application/json", "time": t}
            try:
                d = get_json("https://geo.weather.gc.ca/geomet?" + urllib.parse.urlencode(q), timeout=15)
                feats = d.get("features") or []
                v = (feats[0].get("properties", {}).get("value") if feats else 0) or 0
            except Exception:
                return None
            frame = max(frame, float(v))   # the two layers are the same echo read two ways
        vals.append(frame)
    return sum(vals) / len(vals)


WET_CODES = ("DZ", "RA", "SN", "SG", "PL", "UP")


def observe(lat, lon, hour_start, now):
    """One hour's truth at a place: {temp, temp_src, wet, wet_src}. Fields are None when unknown."""
    row = {"t": hour_start, "temp": None, "temp_src": None, "wet": None, "wet_src": None}
    near_top = lambda x: abs(x["t"] - hour_start) <= 40 * 60    # noqa: E731
    mets = metars(lat, lon)
    sws = swob(lat, lon, now)
    nets = netatmo(lat, lon)

    official = [x for x in sws + mets if x["temp"] is not None and x["km"] <= LOCAL_KM and near_top(x)]
    if official:
        best = min(official, key=lambda x: x["km"])
        row["temp"], row["temp_src"] = round(best["temp"], 1), f"station {best['name']} {best['km']:.0f} km"
    else:
        homes = [x["temp"] for x in nets if x["temp"] is not None and x["km"] <= NETATMO_KM and near_top(x)]
        if len(homes) >= 3:
            row["temp"], row["temp_src"] = round(statistics.median(homes), 1), f"{len(homes)} Netatmo stations"

    reasons, dry_evidence = [], False
    rate = radar_mean_rate(lat, lon, hour_start) if in_canada(lat, lon) else None
    if rate is not None:
        if rate >= WET_MM:
            reasons.append(f"radar {rate:.1f} mm/h")
        elif rate < 0.1:
            dry_evidence = True
    recent = [x for x in mets if x["km"] <= RAIN_REPORT_KM and hour_start - 3600 <= x["t"] <= hour_start + 600]
    wet_metar = [x for x in recent if any(c in x["wx"] for c in WET_CODES)]
    if wet_metar:
        reasons.append(f"{wet_metar[0]['name']} reports {wet_metar[0]['wx']}")
    elif recent and rate is None:
        dry_evidence = True
    gauges = [x for x in sws if x.get("rain1h") is not None and x["km"] <= LOCAL_KM] + \
             [x for x in nets if x.get("rain1h") is not None and x["km"] <= NETATMO_KM]
    if any(x["rain1h"] >= WET_MM for x in gauges):
        reasons.append("rain gauge")
    if reasons:
        row["wet"], row["wet_src"] = 1, "; ".join(reasons)
    elif dry_evidence:
        row["wet"], row["wet_src"] = 0, "radar dry" if rate is not None else "station dry"
    return row


# ---------------------------------------------------------------- forecasts
_regions = {"t": 0, "d": None}


def regions():
    if _regions["d"] is None or time.time() - _regions["t"] > 86400:
        try:
            _regions["d"] = get_json(REGIONS_URL)
            save(path("blend-regions.json"), _regions["d"])
        except Exception as e:
            log("  regions fetch failed", e)
            _regions["d"] = _regions["d"] or load(path("blend-regions.json"), None)
        _regions["t"] = time.time()
    return _regions["d"]


def region_for(lat, lon):
    d = regions()
    for r in d["regions"]:
        for la0, la1, lo0, lo1 in r["boxes"]:
            if la0 <= lat <= la1 and lo0 <= lon <= lo1:
                return r
    return d["global"]


def weight(by_day, model, lead):
    """ModelBlend.interpolatedPrior: day rows centred 12 h + 24 h·i ahead, linear in between."""
    x = min(max((lead - 12) / 24, 0), len(by_day) - 1)
    i = int(x)
    j = min(i + 1, len(by_day) - 1)
    f = x - i
    return by_day[i].get(model, 0) * (1 - f) + by_day[j].get(model, 0) * f


def forecast(lat, lon, now):
    reg = region_for(lat, lon)
    names = [m for m in reg["models"] if m in MODEL_IDS]
    ids = [MODEL_IDS[m] for m in names]
    q = {"latitude": f"{lat:.2f}", "longitude": f"{lon:.2f}", "timezone": "GMT", "forecast_days": FC_DAYS,
         "hourly": "temperature_2m,precipitation,precipitation_probability",
         "models": ",".join(["best_match"] + ids)}
    d = get_json("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q), timeout=30)
    h = d["hourly"]
    times = [datetime.fromisoformat(t).replace(tzinfo=timezone.utc).timestamp() for t in h["time"]]
    hours = {}
    for k, t in enumerate(times):
        lead = (t - now) / 3600
        if lead < 1:
            continue
        num = den = 0.0
        wet = n = 0
        for name, mid in zip(names, ids):
            tv = (h.get(f"temperature_2m_{mid}") or [None] * len(times))[k]
            pv = (h.get(f"precipitation_{mid}") or [None] * len(times))[k]
            if tv is not None:
                w = weight(reg["byDay"], name, lead)
                num += w * tv
                den += w
            if pv is not None:
                n += 1
                wet += pv >= WET_MM
        if den <= 0:
            continue
        pop = (h.get("precipitation_probability_best_match") or [None] * len(times))[k]
        hours[str(int(t))] = [round(num / den, 2), round(wet / n, 2) if n >= 3 else None,
                              None if pop is None else round(pop / 100, 2)]
    return {"t": now, "region": reg["id"], "hours": hours}


# ---------------------------------------------------------------- learning
def decay(age_s):
    return 0.5 ** (age_s / 86400 / HALF_LIFE_DAYS)


def bin_of(t):
    return int((t % 86400) // 10800)


def pairs(fcs, obs):
    """[(issued, valid, lead_h, temp_err, p_wetshare, p_pop, wet)] where there's a truth."""
    by_t = {r["t"]: r for r in obs}
    out = []
    for f in fcs:
        for vs, (temp, share, pop) in f["hours"].items():
            v = int(vs)
            o = by_t.get(v)
            if not o:
                continue
            err = None if o["temp"] is None else temp - o["temp"]
            out.append((f["t"], v, (v - f["t"]) / 3600, err, share, pop, o["wet"]))
    return out


def fit_temperature(ps, cutoff):
    """8 three-hour biases (°C, + = forecast warm) from pairs whose valid time is before `cutoff`."""
    per_hour = {}
    for issued, v, lead, err, *_ in ps:
        if err is None or v >= cutoff or lead < 6 or lead > 120:
            continue
        per_hour.setdefault(v, []).append(err)
    s, w, n = [0.0] * 8, [0.0] * 8, [0] * 8
    for v, errs in per_hour.items():
        b = bin_of(v)
        wt = decay(cutoff - v)
        s[b] += wt * sum(errs) / len(errs)
        w[b] += wt
        n[b] += 1
    raw = [(s[i] / w[i]) * (n[i] / (n[i] + TEMP_SHRINK_HOURS)) if w[i] > 0 else 0.0 for i in range(8)]
    smooth = [0.25 * raw[i - 1] + 0.5 * raw[i] + 0.25 * raw[(i + 1) % 8] for i in range(8)]
    return [round(max(-TEMP_CAP, min(TEMP_CAP, x)), 2) for x in smooth]


def bias_at(bins, t):
    """ModelBlend.diurnalBias: bins centred at 01:30, 04:30, ... UTC, linear in between."""
    pos = ((t % 86400) / 3600 - 1.5) / 3
    lo = math.floor(pos)
    f = pos - lo
    return bins[lo % 8] * (1 - f) + bins[(lo + 1) % 8] * f


def fit_rain(ps, cutoff):
    """Multiplier on the chance of rain from pairs before `cutoff` (lead 1-48 h)."""
    per_hour = {}
    for issued, v, lead, err, share, pop, wet in ps:
        if wet is None or pop is None or v >= cutoff or lead > 48:
            continue
        per_hour.setdefault(v, [wet, []])[1].append(pop)
    O = P = 0.0
    for v, (wet, pops) in per_hour.items():
        wt = decay(cutoff - v)
        O += wt * wet
        P += wt * sum(pops) / len(pops)
    factor = (O + POP_PRIOR) / (P + POP_PRIOR)
    return round(max(POP_RANGE[0], min(POP_RANGE[1], factor)), 3)


def check(ps, now, fit, score):
    """Held-out check over the last CHECK_DAYS: each 00/12 UTC forecast corrected with a fit made
    from data before it was issued. Returns (raw score, learned score, count, days)."""
    start = now - CHECK_DAYS * 86400
    by_issue = {}
    for p in ps:
        if p[0] >= start and int(p[0]) % 43200 < 3600:      # the 00 and 12 UTC forecasts
            by_issue.setdefault(p[0], []).append(p)
    raw = lrn = 0.0
    n = 0
    days = set()
    for issued, rows in by_issue.items():
        model = fit(ps, issued)
        r, l, k = score(model, rows)
        raw += r
        lrn += l
        n += k
        if k:
            days.add(int(issued // 86400))
    return raw, lrn, n, len(days)


def temp_score(bins, rows):
    r = l = 0.0
    k = 0
    for issued, v, lead, err, *_ in rows:
        if err is None or lead < 6 or lead > 120:
            continue
        r += abs(err)
        l += abs(err - bias_at(bins, v))
        k += 1
    return r, l, k


def rain_score(factor, rows):
    r = l = 0.0
    k = 0
    for issued, v, lead, err, share, pop, wet in rows:
        if wet is None or pop is None or lead > 48:
            continue
        r += (pop - wet) ** 2
        l += (min(1.0, pop * factor) - wet) ** 2
        k += 1
    return r, l, k


def timing(ps, now):
    """Hours (−3..3) the chance of rain would best be shifted by, over the last 30 days, lead ≤ 24 h."""
    since = now - 30 * 86400
    rows = [p for p in ps if p[1] >= since and p[6] is not None and p[5] is not None and p[2] <= 24]
    if sum(p[6] for p in rows) < 10:
        return None
    wet_at = {p[1]: p[6] for p in rows}
    best = (None, None)
    base = None
    for lag in range(-3, 4):
        tot = k = 0
        for issued, v, lead, err, share, pop, wet in rows:
            o = wet_at.get(v + lag * 3600)
            if o is None:
                continue
            tot += (pop - o) ** 2
            k += 1
        if not k:
            continue
        b = tot / k
        if lag == 0:
            base = b
        if best[1] is None or b < best[1]:
            best = (lag, b)
    if base is None or best[0] is None:
        return None
    if best[1] > GAIN * base:      # no shift is clearly better: call it on time
        best = (0, base)
    return {"best_shift_h": best[0], "brier_now": round(base, 4), "brier_shifted": round(best[1], 4),
            "note": "+ means rain here tends to come later than forecast"}


def learn(cell, now):
    key = cell.replace(",", "_")
    since = now - KEEP_DAYS * 86400
    fcs = read_jsonl(path("fc", key + ".jsonl"), since)
    obs = read_jsonl(path("obs", key + ".jsonl"), since)
    ps = pairs(fcs, obs)
    days = len({int(r["t"] // 86400) for r in obs if r["temp"] is not None or r["wet"] is not None})
    srcs = [r["temp_src"] for r in obs[-72:] if r["temp_src"]]
    wsrcs = [r["wet_src"] for r in obs[-72:] if r["wet_src"]]
    out = {"cell": cell, "updated": int(now), "days": days, "status": "learning",
           "temperature": {"enabled": False}, "rain": {"enabled": False}}

    t_raw, t_lrn, t_n, t_days = check(ps, now, fit_temperature, temp_score)
    bins = fit_temperature(ps, now)
    t_ok = days >= MIN_DAYS and t_days >= 7 and t_n > 0 and t_lrn <= GAIN * t_raw
    out["temperature"] = {
        "enabled": bool(t_ok), "bias_3h": bins if t_ok else [0.0] * 8, "measured_bias_3h": bins,
        "mae_raw": round(t_raw / t_n, 2) if t_n else None, "mae_learned": round(t_lrn / t_n, 2) if t_n else None,
        "checked_pairs": t_n, "checked_days": t_days,
        "truth": max(set(srcs), key=srcs.count) if srcs else None,
    }
    r_raw, r_lrn, r_n, r_days = check(ps, now, fit_rain, rain_score)
    factor = fit_rain(ps, now)
    wet_checked = sum(1 for p in ps if p[0] >= now - CHECK_DAYS * 86400 and p[6] == 1 and p[2] <= 48)
    r_ok = days >= MIN_DAYS and r_days >= 7 and r_n > 0 and wet_checked >= 10 and r_lrn <= GAIN * r_raw
    wet_obs = [r for r in obs if r["wet"] == 1]
    missed = [p for p in ps if p[6] == 1 and p[2] <= 12 and (p[4] or 0) < 0.34 and (p[5] or 0) < 0.3]
    near = [p for p in ps if p[6] == 1 and p[2] <= 12]
    out["rain"] = {
        "enabled": bool(r_ok), "pop_factor": factor if r_ok else 1.0, "measured_pop_factor": factor,
        "brier_raw": round(r_raw / r_n, 4) if r_n else None, "brier_learned": round(r_lrn / r_n, 4) if r_n else None,
        "checked_pairs": r_n, "checked_days": r_days, "wet_hours": len(wet_obs),
        "hours_with_truth": sum(1 for r in obs if r["wet"] is not None),
        "missed_light_share": round(len(missed) / len(near), 3) if near else None,
        "timing": timing(ps, now),
        "truth": max(set(wsrcs), key=wsrcs.count) if wsrcs else None,
    }
    if t_ok or r_ok:
        out["status"] = "correcting"
    elif days >= MIN_DAYS:
        out["status"] = "no proven gain"
    save(path("learned", key + ".json"), out)
    return out


# ---------------------------------------------------------------- the hourly run
def run(now=None):
    now = now or time.time()
    hour_start = int(now // 3600) * 3600
    places = load(path("places.json"), {})
    # Pinned places (learner.py pin) are learned whether or not anyone opens the app there.
    active = [c for c, p in places.items()
              if p.get("pinned") or now - p.get("last_seen", 0) <= ACTIVE_DAYS * 86400]
    log(f"run: {len(active)} active places")
    for cell in sorted(active):
        lat, lon = cell_centre(cell)
        key = cell.replace(",", "_")
        try:
            row = observe(lat, lon, hour_start, now)
            append_jsonl(path("obs", key + ".jsonl"), row)
            if (hour_start // 3600) % FC_EVERY_H == 0:
                append_jsonl(path("fc", key + ".jsonl"), forecast(lat, lon, now))
            res = learn(cell, now)
            log(f"  {cell}: temp {row['temp']} ({row['temp_src']}), wet {row['wet']} ({row['wet_src']}); "
                f"{res['status']}, {res['days']} days")
        except Exception as e:
            log(f"  {cell}: failed {e!r}")
        if hour_start % 86400 == 0:
            trim_jsonl(path("obs", key + ".jsonl"), now - KEEP_DAYS * 86400)
            trim_jsonl(path("fc", key + ".jsonl"), now - (KEEP_DAYS + FC_DAYS) * 86400)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run()
    elif cmd == "show":
        print(json.dumps(lookup(float(sys.argv[2]), float(sys.argv[3]), register=False), indent=1))
    elif cmd == "add":
        print(json.dumps(lookup(float(sys.argv[2]), float(sys.argv[3]), register=True), indent=1))
    elif cmd == "pin":
        lookup(float(sys.argv[2]), float(sys.argv[3]), register=True)
        places = load(path("places.json"), {})
        cell = cell_of(float(sys.argv[2]), float(sys.argv[3]))
        places[cell]["pinned"] = True
        if len(sys.argv) > 4:
            places[cell]["name"] = " ".join(sys.argv[4:])
        save(path("places.json"), places)
        print(cell, json.dumps(places[cell]))
    else:
        sys.exit("usage: learner.py run | show LAT LON | add LAT LON | pin LAT LON [NAME]")
