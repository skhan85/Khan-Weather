#!/usr/bin/env python3
"""Radar-motion nowcast from RainViewer frames, and a check that it beats "radar now stays put".

This is the reference for the app's RadarMotion (Packages/WeatherCore/.../RadarMotion.swift and
android/core/.../RadarMotion.kt), used wherever Environment Canada's own radar extrapolation
(relay /v1/nowcast) doesn't reach:

- 2x2 RainViewer tiles at zoom 6 around the spot (Universal Blue colours, no smoothing), from the
  newest frame and the one 20 minutes before it.
- Colour -> dBZ with RainViewer's published table, dBZ -> rain rate (Marshall-Palmer, Z=200R^1.6).
- The motion is the shift that best lines up the old frame with the new one over a window about
  170 km across around the spot (log rain rate, only where either frame has an echo), up to
  110 km/h.
- The rain at the spot L minutes ahead is the newest frame's rain upstream at spot - motion x L
  (3x3 pixel mean), for up to 90 minutes.

`python3 radar_motion.py` scores it at about 60 cities: motion from the frames 110 and 90 minutes
old, forecast from the 90-minute-old frame, compared with the frames that followed (up to 90
minutes ahead), against persistence (the 90-minute-old radar unchanged). Each run appends its cases
to radar-motion-cases.jsonl so several runs add up.
"""
import io, json, math, os, sys, time, urllib.request

import numpy as np
from PIL import Image

ZOOM = 6
TILE = 256
WINDOW = 48             # half-size of the matching window, px (~85 km at 45°)
MAX_SPEED = 110         # km/h
MIN_ECHO_PX = 20        # fewer echo pixels in the window: no motion, the frame stays put
MAX_LEAD = 90           # minutes
MIN_DBZ = 10

# RainViewer Universal Blue (scheme 2), rain colours, dBZ -10..64 (above 64 it's clutter colours).
UB = {-10: "63615914", -9: "66635a19", -8: "69665c1e", -7: "6c685d24", -6: "6f6b5f29", -5: "726e612e",
      -4: "75706234", -3: "78736439", -2: "7c75653e", -1: "7f786744", 0: "827b6949", 1: "857d6a4e",
      2: "88806c54", 3: "8b826d59", 4: "8e856f5e", 5: "92887164", 6: "9e93756e", 7: "aa9e7978",
      8: "b6a97e82", 9: "c2b4828c", 10: "cec08796", 11: "d2c48ba0", 12: "d6c88faa", 13: "dacc93b4",
      14: "ded097be", 15: "88ddeeff", 16: "6cd1ebff", 17: "51c5e8ff", 18: "36bae5ff", 19: "1baee2ff",
      20: "00a3e0ff", 21: "009ad5ff", 22: "0091caff", 23: "0088bfff", 24: "007fb4ff", 25: "0077aaff",
      26: "0070a3ff", 27: "00699cff", 28: "006295ff", 29: "005b8eff", 30: "005588ff", 31: "005180ff",
      32: "004e78ff", 33: "004a70ff", 34: "004768ff", 35: "ffee00ff", 36: "ffe000ff", 37: "ffd200ff",
      38: "ffc500ff", 39: "ffb700ff", 40: "ffaa00ff", 41: "ff9f00ff", 42: "ff9500ff", 43: "ff8b00ff",
      44: "ff8100ff", 45: "ff4400ff", 46: "f23600ff", 47: "e62800ff", 48: "d91b00ff", 49: "cd0d00ff",
      50: "c10000ff", 51: "a80000ff", 52: "8f0000ff", 53: "760000ff", 54: "5d0000ff", 55: "ffaaffff",
      56: "ff9fffff", 57: "ff95ffff", 58: "ff8bffff", 59: "ff81ffff", 60: "ff77ffff", 61: "ff6cffff",
      62: "ff62ffff", 63: "ff58ffff", 64: "ff4effff"}
UB_DBZ = np.array(sorted(UB), dtype=np.float32)
UB_RGB = np.array([[int(UB[d][i:i + 2], 16) for i in (0, 2, 4)] for d in sorted(UB)], dtype=np.float32)


def dbz_from_rgba(px):
    """px: (..., 4) uint8 -> dBZ (nan where no echo). Nearest colour in the table."""
    rgb = px[..., :3].astype(np.float32)
    a = px[..., 3]
    d2 = ((rgb[..., None, :] - UB_RGB) ** 2).sum(-1)
    out = UB_DBZ[d2.argmin(-1)]
    return np.where(a >= 16, out, np.nan)


def rate(dbz):
    """Rain rate mm/h from dBZ; 0 below MIN_DBZ or without an echo."""
    z = np.power(10.0, np.nan_to_num(dbz, nan=-99) / 10.0)
    r = np.power(z / 200.0, 1 / 1.6)
    return np.where(np.nan_to_num(dbz, nan=-99) >= MIN_DBZ, r, 0.0)


def global_px(lat, lon, zoom=ZOOM):
    n = TILE * 2 ** zoom
    x = (lon + 180) / 360 * n
    s = math.radians(lat)
    y = (1 - math.log(math.tan(s) + 1 / math.cos(s)) / math.pi) / 2 * n
    return x, y


def tiles_for(lat, lon):
    x, y = global_px(lat, lon)
    tx0, ty0 = round(x / TILE) - 1, round(y / TILE) - 1
    return tx0, ty0, x - tx0 * TILE, y - ty0 * TILE


def px_km(lat, zoom=ZOOM):
    return 40075.016 * math.cos(math.radians(lat)) / (TILE * 2 ** zoom)


def motion(old, new, cx, cy, minutes, km):
    """Best shift (dx, dy) px from old to new, per minute; (0, 0) when there's too little echo."""
    reach = int(math.ceil(MAX_SPEED * minutes / 60 / km))
    h, w = new.shape
    x0, x1 = max(int(cx) - WINDOW, reach), min(int(cx) + WINDOW, w - reach - 1)
    y0, y1 = max(int(cy) - WINDOW, reach), min(int(cy) + WINDOW, h - reach - 1)
    if x1 <= x0 or y1 <= y0:
        return 0.0, 0.0
    a = np.log1p(new[y0:y1, x0:x1])
    if (a > 0).sum() < MIN_ECHO_PX:
        return 0.0, 0.0
    lo = np.log1p(old)
    best, bx, by = None, 0, 0
    zero = None
    for dy in range(-reach, reach + 1):
        for dx in range(-reach, reach + 1):
            b = lo[y0 - dy:y1 - dy, x0 - dx:x1 - dx]
            m = (a > 0) | (b > 0)
            n = m.sum()
            if n < MIN_ECHO_PX:
                continue
            c = np.abs(a - b)[m].mean()
            if dx == 0 and dy == 0:
                zero = c
            if best is None or c < best:
                best, bx, by = c, dx, dy
    if best is None or (zero is not None and best > zero * 0.98):
        return 0.0, 0.0
    return bx / minutes, by / minutes


def sample(grid, x, y):
    h, w = grid.shape
    xi, yi = int(round(x)), int(round(y))
    if xi < 1 or yi < 1 or xi >= w - 1 or yi >= h - 1:
        return None
    return float(grid[yi - 1:yi + 2, xi - 1:xi + 2].mean())


def forecast(grid, cx, cy, vx, vy, leads):
    return [sample(grid, cx - vx * L, cy - vy * L) for L in leads]


# ---------- fetching ----------
def get(url, kind="bytes"):
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "khan-weather-verify"})
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read()
            return json.loads(body) if kind == "json" else body
        except Exception as e:
            print("  retry", attempt, url[-80:], e, file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    return None


_tiles = {}


def mosaic(host, path, tx0, ty0):
    out = np.zeros((2 * TILE, 2 * TILE), dtype=np.float32)
    for j in range(2):
        for i in range(2):
            url = f"{host}{path}/{TILE}/{ZOOM}/{tx0 + i}/{ty0 + j}/2/0_0.png"
            if url not in _tiles:
                body = get(url)
                time.sleep(0.7)     # RainViewer asks for under 100 requests a minute
                _tiles[url] = None if body is None else np.array(Image.open(io.BytesIO(body)).convert("RGBA"))
            px = _tiles[url]
            if px is None:
                return None
            out[j * TILE:(j + 1) * TILE, i * TILE:(i + 1) * TILE] = rate(dbz_from_rgba(px))
    return out


CITIES = [
    ("Hillsboro", 45.52, -122.99), ("Seattle", 47.61, -122.33), ("San Francisco", 37.77, -122.42),
    ("Los Angeles", 34.05, -118.24), ("Denver", 39.74, -104.99), ("Dallas", 32.78, -96.80),
    ("Houston", 29.76, -95.37), ("Chicago", 41.88, -87.63), ("Minneapolis", 44.98, -93.27),
    ("Atlanta", 33.75, -84.39), ("Orlando", 28.66, -81.37), ("Miami", 25.76, -80.19),
    ("Washington", 38.91, -77.04), ("New York", 40.71, -74.01), ("Boston", 42.36, -71.06),
    ("Detroit", 42.33, -83.05), ("Nashville", 36.16, -86.78), ("Phoenix", 33.45, -112.07),
    ("Salt Lake City", 40.76, -111.89), ("Kansas City", 39.10, -94.58),
    ("Milton", 43.52, -79.88), ("Montreal", 45.50, -73.57), ("Halifax", 44.65, -63.57),
    ("Vancouver", 49.28, -123.12), ("Calgary", 51.05, -114.07), ("Winnipeg", 49.90, -97.14),
    ("London", 51.51, -0.13), ("Manchester", 53.48, -2.24), ("Dublin", 53.35, -6.26),
    ("Paris", 48.86, 2.35), ("Brussels", 50.85, 4.35), ("Amsterdam", 52.37, 4.90),
    ("Frankfurt", 50.11, 8.68), ("Munich", 48.14, 11.58), ("Berlin", 52.52, 13.40),
    ("Copenhagen", 55.68, 12.57), ("Stockholm", 59.33, 18.07), ("Oslo", 59.91, 10.75),
    ("Warsaw", 52.23, 21.01), ("Vienna", 48.21, 16.37), ("Zurich", 47.38, 8.54),
    ("Milan", 45.46, 9.19), ("Rome", 41.90, 12.50), ("Madrid", 40.42, -3.70), ("Lisbon", 38.72, -9.14),
    ("Prague", 50.08, 14.44), ("Budapest", 47.50, 19.04), ("Helsinki", 60.17, 24.94),
    ("Tokyo", 35.68, 139.69), ("Osaka", 34.69, 135.50), ("Seoul", 37.57, 126.98),
    ("Taipei", 25.03, 121.57), ("Sydney", -33.87, 151.21), ("Melbourne", -37.81, 144.96),
    ("Brisbane", -27.47, 153.03), ("Auckland", -36.85, 174.76), ("Sao Paulo", -23.55, -46.63),
    ("Johannesburg", -26.20, 28.05), ("Lahore", 31.55, 74.34), ("Istanbul", 41.01, 28.98),
]
WET = 0.5   # mm/h


def check():
    meta = get("https://api.rainviewer.com/public/weather-maps.json", "json")
    if not meta:
        print("no RainViewer index")
        return
    host = meta["host"]
    past = meta["radar"]["past"]
    by_time = {f["time"]: f["path"] for f in past}
    times = sorted(by_time)
    t_new = times[-1]
    # Frames 110 and 90 minutes before the newest: motion; then 90 -> 0 minutes ahead to check.
    def frame_at(t):
        cand = min(times, key=lambda x: abs(x - t))
        return cand if abs(cand - t) <= 300 else None
    f60, f40 = frame_at(t_new - 6600), frame_at(t_new - 5400)
    if not f60 or not f40:
        print("not enough past frames", times)
        return
    later = [t for t in times if t > f40]
    cases = []
    for name, lat, lon in CITIES:
        tx0, ty0, cx, cy = tiles_for(lat, lon)
        km = px_km(lat)
        g60 = mosaic(host, by_time[f60], tx0, ty0)
        g40 = mosaic(host, by_time[f40], tx0, ty0)
        if g60 is None or g40 is None:
            continue
        if (g40 > 0).sum() == 0:
            continue
        vx, vy = motion(g60, g40, cx, cy, (f40 - f60) / 60, km)
        # Score at the spot and at 24 points on a ring 30-60 km out, where it's raining nearby.
        pts = [(cx, cy)] + [(cx + r / km * math.cos(a), cy + r / km * math.sin(a))
                            for r in (30, 60) for a in np.linspace(0, 2 * math.pi, 12, endpoint=False)]
        truth = {t: mosaic(host, by_time[t], tx0, ty0) for t in later}
        for (x, y) in pts:
            for t in later:
                g = truth[t]
                if g is None:
                    continue
                lead = (t - f40) / 60
                obs = sample(g, x, y)
                mot = sample(g40, x - vx * lead, y - vy * lead)
                per = sample(g40, x, y)
                if obs is None or mot is None or per is None:
                    continue
                if max(obs, mot, per) <= 0:
                    continue
                cases.append({"city": name, "issued": f40, "lead": round(lead), "obs": round(obs, 2),
                              "motion": round(mot, 2), "persist": round(per, 2),
                              "speed_kmh": round(math.hypot(vx, vy) * km * 60, 1)})
        print(f"{name}: motion {math.hypot(vx, vy) * km * 60:.0f} km/h", file=sys.stderr, flush=True)
    with open("radar-motion-cases.jsonl", "a") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
    summarise()


def summarise(path="radar-motion-cases.jsonl"):
    rows = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
    issued = len({(r["city"], r["issued"]) for r in rows})
    print(f"\n{len(rows)} cases from {issued} city-frames")
    print("lead  n     CSI motion  CSI persist  MAE motion  MAE persist  (wet = 0.5 mm/h)")
    for lo, hi in ((5, 15), (16, 30), (31, 60), (61, 90)):
        rr = [r for r in rows if lo <= r["lead"] <= hi]
        if not rr:
            continue
        def csi(k):
            h = sum(r[k] >= WET and r["obs"] >= WET for r in rr)
            m = sum(r[k] < WET and r["obs"] >= WET for r in rr)
            fa = sum(r[k] >= WET and r["obs"] < WET for r in rr)
            return h / max(1, h + m + fa)
        mae = lambda k: sum(abs(r[k] - r["obs"]) for r in rr) / len(rr)
        print(f"{lo:>2}-{hi:<2} {len(rr):>6}  {csi('motion'):.3f}       {csi('persist'):.3f}        "
              f"{mae('motion'):.3f}       {mae('persist'):.3f}")


if __name__ == "__main__":
    if sys.argv[1:] == ["summary"]:
        summarise()
    else:
        check()
