#!/usr/bin/env python3
"""Probe free national forecast sources from a GitHub runner: prints status and a short sample of
each, so the scorer and logger can be written against what the services really return."""
import io, json, sys, urllib.error, urllib.parse, urllib.request, zipfile

UA = "weather-verify/1.0"


def get(url, n=600, binary=False, headers=None):
    h = {"User-Agent": UA, "Accept": "application/geo+json, application/json, */*"}
    h.update(headers or {})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=40) as r:
            body = r.read()
            print(f"\n== {r.status} {url}")
    except urllib.error.HTTPError as e:
        print(f"\n== HTTP {e.code} {url}\n{e.read()[:300]!r}")
        return None
    except Exception as e:
        print(f"\n== FAIL {url}: {e}")
        return None
    if binary:
        print(f"   {len(body)} bytes")
        return body
    t = body.decode("utf-8", "replace")
    print(t[:n])
    return t


# IEM MOS archive (US NWS MOS, LAMP, NBM station text)
for st, model in [("KHIO", "LAV"), ("KHIO", "NBS"), ("KHIO", "GFS"), ("KHIO", "MEX"), ("KHIO", "NBE"),
                  ("CYYZ", "GFS"), ("CYYZ", "NBS"), ("KORD", "ECM"), ("KORD", "ECMWF")]:
    get(f"https://mesonet.agron.iastate.edu/api/1/mos.json?station={st}&model={model}", 700)
get("https://mesonet.agron.iastate.edu/api/1/mos.json?station=KHIO&model=NBS&runtime=2026-07-01%2012:00Z", 400)
get("https://mesonet.agron.iastate.edu/api/1/mos.json?station=KHIO&model=LAV&runtime=2026-07-01%2012:00Z", 400)

# Open-Meteo single runs: candidate national models not yet scored
cands = ["bom_access_global", "kma_seamless", "kma_gdps", "kma_ldps", "cma_grapes_global", "jma_gsm", "jma_msm",
         "jma_seamless", "italia_meteo_arpae_icon_2i", "meteoswiss_icon_seamless", "meteoswiss_icon_ch1",
         "ukmo_uk_deterministic_2km", "ukmo_global_deterministic_10km", "metno_nordic", "gem_regional",
         "ncep_aigfs025", "ncep_hgefs025", "ncep_nbm_conus", "knmi_harmonie_arome_europe",
         "dmi_harmonie_arome_europe", "geosphere_arome_austria", "ecmwf_aifs025_single", "ncep_gfs_graphcast025",
         "icon_d2", "icon_eu", "meteofrance_arome_france_hd", "ncep_rrfs_conus"]
places = {"oceania": (-33.95, 151.18), "east_asia": (35.55, 139.78), "seoul": (37.46, 126.44),
          "europe": (51.47, -0.45), "zurich": (47.46, 8.55), "rome": (41.8, 12.24), "oslo": (60.19, 11.1),
          "na": (43.68, -79.63), "lahore": (31.52, 74.4)}
for m in cands:
    for run in ["2026-05-10T00:00", "2026-10-20T12:00"]:
        for pname, (la, lo) in places.items():
            q = {"latitude": la, "longitude": lo, "hourly": "temperature_2m", "models": m, "run": run,
                 "timezone": "GMT", "forecast_days": 7}
            t = None
            try:
                url = "https://single-runs-api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q)
                with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=40) as r:
                    d = json.load(r)
                v = d["hourly"]["temperature_2m"]
                good = sum(x is not None for x in v)
                t = f"{good}/{len(v)} hours"
            except urllib.error.HTTPError as e:
                t = f"HTTP {e.code} {e.read()[:120]!r}"
            except Exception as e:
                t = f"FAIL {e}"
            print(f"SR {m} {run} {pname}: {t}")

# NWS
t = get("https://api.weather.gov/points/45.5409,-122.9498", 300)
if t:
    p = json.loads(t)["properties"]
    g = get(p["forecastGridData"], 200)
    if g:
        tt = json.loads(g)["properties"]["temperature"]
        print("NWS temperature", tt.get("uom"), tt["values"][:5])
        print("NWS updateTime", json.loads(g)["properties"].get("updateTime"))

# MET Norway locationforecast
t = get("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=51.47&lon=-0.45", 200)
if t:
    d = json.loads(t)
    ts = d["properties"]["timeseries"]
    print("METNO", d["properties"]["meta"], len(ts), ts[0]["time"], ts[0]["data"]["instant"]["details"], ts[-1]["time"])

# DWD MOSMIX: station catalogue and one station file
cat = get("https://www.dwd.de/DE/leistungen/met_verfahren_mosmix/mosmix_stationskatalog.cfg?view=nasPublication&nn=16102", 800)
if cat:
    for line in cat.splitlines():
        if any(k in line for k in ("CYYZ", "OPLA", "KHIO", "KPDX", "EGLL", "KORL", "KMCO", "PEARSON", "LAHORE")):
            print("CAT", line)
for sid in ["71624", "41640", "03772", "72698", "10637"]:
    b = get(f"https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/single_stations/{sid}/kml/MOSMIX_L_LATEST_{sid}.kmz", binary=True)
    if b:
        z = zipfile.ZipFile(io.BytesIO(b))
        x = z.read(z.namelist()[0]).decode("utf-8", "replace")
        i = x.find("ForecastTimeSteps")
        j = x.find('elementName="TTT"')
        print("MOSMIX", sid, x[i:i + 200].replace("\n", " "), "|", x[j:j + 200].replace("\n", " "))
        k = x.find("IssueTime")
        print("  issue", x[k:k + 60])

# Met Office DataHub (needs key; check reachability only)
get("https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/hourly?latitude=51.47&longitude=-0.45", 200)
# Hong Kong Observatory, BoM unofficial, JMA, ECCC
get("https://api.weather.bom.gov.au/v1/locations/r3gx2f/forecasts/hourly", 300)
get("https://www.jma.go.jp/bosai/forecast/data/forecast/130000.json", 300)
get("https://api.weather.gc.ca/collections?f=json", 200)
get("https://api.weather.gc.ca/collections/citypageweather-realtime/items?f=json&limit=1", 400)
