#!/usr/bin/env python3
"""One-off probe: which Open-Meteo models have single-run archives, and does IEM serve global METARs."""
import json, urllib.parse, urllib.request

def get(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code} {e.read().decode()[:200]}"
    except Exception as e:
        return f"ERR {e}"

MODELS = ["gem_seamless", "gem_hrdps_continental", "gfs_seamless", "gfs_hrrr", "ncep_nbm_conus",
          "ecmwf_ifs025", "ecmwf_ifs", "ecmwf_aifs025_single", "icon_seamless", "ukmo_seamless",
          "ukmo_uk_deterministic_2km", "meteofrance_seamless", "knmi_seamless", "dmi_seamless",
          "metno_seamless", "meteoswiss_icon_seamless", "italia_meteo_arpae_icon_2i", "jma_seamless",
          "kma_seamless", "bom_access_global", "cma_grapes_global", "best_match", "gem_regional"]
SPOTS = {"London": (51.47, -0.45), "Toronto": (43.68, -79.63), "Tokyo": (35.55, 139.78),
         "Sydney": (-33.95, 151.18), "Karachi": (24.9, 67.16)}
for name, (lat, lon) in SPOTS.items():
    for api, extra in (("single-runs-api", {"run": "2026-06-01T00:00", "forecast_days": 7}),
                       ("previous-runs-api", {"start_date": "2026-06-01", "end_date": "2026-06-02",
                                              "hourly": "temperature_2m,temperature_2m_previous_day3"})):
        ok, bad = [], []
        for m in MODELS:
            q = {"latitude": lat, "longitude": lon, "hourly": "temperature_2m", "models": m, "timezone": "GMT"}
            q.update(extra)
            body = get(f"https://{api}.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q))
            try:
                h = json.loads(body)["hourly"]
                vals = [v for k, v in h.items() if k != "time"]
                n = [sum(x is not None for x in v) for v in vals]
                (ok if max(n) > 0 else bad).append(f"{m}:{n}")
            except Exception:
                bad.append(f"{m}:{body[:80]}")
        print(name, api, "\n  OK", ok, "\n  NO", bad, flush=True)

for st in ["CYYZ", "EGLL", "RJTT", "YSSY", "OPKC", "OMDB", "SBGR", "FAOR"]:
    q = {"station": st, "data": "tmpc", "year1": 2026, "month1": 6, "day1": 1, "year2": 2026, "month2": 6,
         "day2": 2, "tz": "Etc/UTC", "format": "onlycomma", "latlon": "yes", "missing": "empty",
         "report_type": [3, 4]}
    body = get("https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?" + urllib.parse.urlencode(q, doseq=True))
    lines = body.strip().splitlines()
    print("IEM", st, len(lines), lines[:3], flush=True)
