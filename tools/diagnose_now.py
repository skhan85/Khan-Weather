"""One-off: what the light-rain clues saw at a spot (default Mississauga) over the last hours."""
import json, sys, urllib.request, urllib.parse
LAT, LON = (float(sys.argv[1]), float(sys.argv[2])) if len(sys.argv) > 2 else (43.59, -79.64)
UA = {"User-Agent": "khan-weather-diagnose"}
def get(u, t=40):
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=t) as r:
            return r.read().decode()
    except Exception as e:
        return f"ERROR {e}"
print("== METARs within ~45 km, last 4 h")
bbox = f"{LAT-0.4},{LON-0.55},{LAT+0.4},{LON+0.55}"
print(get("https://aviationweather.gov/api/data/metar?ids=CYYZ,CYHM,CZBA,CYKZ,CYTZ,CYOO,CYKF&hours=3&format=raw"))
print("== ECCC city pages near")
q = urllib.parse.urlencode({"f": "json", "lang": "en", "limit": "10",
     "bbox": f"{LON-0.6},{LAT-0.4},{LON+0.6},{LAT+0.4}"})
d = get("https://api.weather.gc.ca/collections/citypageweather-realtime/items?" + q)
try:
    for f in json.loads(d)["features"]:
        p = f["properties"]; c = p.get("currentConditions") or {}
        def en(x): return x.get("en") if isinstance(x, dict) else x
        st = c.get("station") or {}
        print(en(p.get("name")), "|", en(st.get("value")) if isinstance(st, dict) else st, "|",
              en(c.get("condition")), "|", json.dumps(c.get("timestamp")), "| RH", json.dumps(c.get("relativeHumidity"))[:60])
except Exception as e:
    print("parse error", e, d[:500])
models = "gem_seamless,gfs_seamless,ecmwf_ifs025,ecmwf_aifs025_single,icon_seamless,ukmo_seamless,gem_hrdps_continental,gfs_hrrr,ncep_nbm_conus,ecmwf_ifs"
print("== Open-Meteo per-model precipitation (mm/h), past 6 h + next 3 h, UTC")
q = urllib.parse.urlencode({"latitude": LAT, "longitude": LON, "hourly": "precipitation,relative_humidity_2m",
     "models": models, "past_hours": 6, "forecast_hours": 3, "timezone": "UTC"})
d = get("https://api.open-meteo.com/v1/forecast?" + q)
try:
    h = json.loads(d)["hourly"]
    for i, t in enumerate(h["time"]):
        row = []
        for m in models.split(","):
            v = (h.get(f"precipitation_{m}") or [None]*99)[i]
            row.append(f"{m.split('_')[0][:4]}{'-'+m.split('_')[1][:4] if '_' in m else ''}={v}")
        wet = sum(1 for m in models.split(",") if ((h.get(f'precipitation_{m}') or [None]*99)[i] or 0) >= 0.2)
        print(t, f"wet(>=0.2)={wet}", " ".join(row))
except Exception as e:
    print("parse error", e, d[:500])
print("== Open-Meteo 15-minute (best match)")
q = urllib.parse.urlencode({"latitude": LAT, "longitude": LON, "minutely_15": "precipitation,rain",
     "past_minutely_15": 8, "forecast_minutely_15": 8, "timezone": "UTC"})
print(get("https://api.open-meteo.com/v1/forecast?" + q)[:1500])
print("== Relay nowcast / learned")
print(get(f"https://weather-relay.khanofmilton.ca/v1/learned?lat={LAT:.2f}&lon={LON:.2f}")[:600])
