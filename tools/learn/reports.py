#!/usr/bin/env python3
""""What's it doing now?" reports from the family's phones, kept on the relay (Saad's VPS).

The app's Now card has a button: Sunny, Cloudy, Drizzle, Raining, Snowing and so on. A report
corrects that phone's card at once, and the relay passes it on:

    POST   /v1/report   {"id", "kind", "t", "lat", "lon"}  -> {"ok": true}
    DELETE /v1/report   {"id"}                             -> {"ok": true}   (the app's Undo)
    GET    /v1/reports?lat=..&lon=..                       -> {"reports": [...]}  last hour, 15 km

so other phones and widgets nearby show it too, and learner.py takes them as the truth for rain
in that hour (a person outside beats a radar beam passing over drizzle).

relay.py hands those three requests to `handle(method, path, query, body, client)`; anything
else returns None and the relay carries on as before. Standard library only. Reports live in
DATA_DIR/reports.jsonl (no IP addresses or device names are stored; coordinates are rounded to
about 100 m by the app).
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import learner as L  # noqa: E402

KINDS = ("clear", "partlyCloudy", "cloudy", "fog", "drizzle", "rain", "heavyRain", "thunderstorm",
         "snow", "rainAndSnow", "freezingRain")
DRY = ("clear", "partlyCloudy", "cloudy", "fog")
SERVE_KM = 15          # the app applies reports within 8 km; a little more so it can decide
SERVE_S = 3600         # the app applies them for 45 minutes
TRUTH_KM = 7           # learner: a report this close to a place's cell centre counts there
KEEP_DAYS = 60
PER_CLIENT_HOUR = 30   # posts per hour from one address (a stuck button, or someone poking at it)
ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")

_recent_posts = {}


def _file():
    return L.path("reports.jsonl")


def _rows(since):
    """Reports since `since`, newest last, with withdrawn ones removed."""
    rows = L.read_jsonl(_file(), since - 600)
    gone = {r["id"] for r in rows if r.get("deleted")}
    return [r for r in rows if not r.get("deleted") and r["id"] not in gone and r["t"] >= since]


def add(body, client="", now=None):
    now = now or time.time()
    try:
        rid, kind = str(body["id"]), str(body["kind"])
        lat, lon = float(body["lat"]), float(body["lon"])
        t = float(body.get("t", now))
    except (KeyError, TypeError, ValueError):
        return 400, {"error": "bad_report"}
    if not ID_RE.match(rid) or kind not in KINDS or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return 400, {"error": "bad_report"}
    # A phone's clock can be off; a report is about now.
    if abs(t - now) > 600:
        t = now
    hits = [x for x in _recent_posts.get(client, []) if now - x < 3600]
    if len(hits) >= PER_CLIENT_HOUR:
        return 429, {"error": "too_many_reports"}
    _recent_posts[client] = hits + [now]
    if any(r["id"] == rid for r in _rows(now - SERVE_S)):
        return 200, {"ok": True, "duplicate": True}
    L.append_jsonl(_file(), {"id": rid, "kind": kind, "t": round(t), "lat": round(lat, 3), "lon": round(lon, 3)})
    return 200, {"ok": True}


def withdraw(body, now=None):
    now = now or time.time()
    rid = str((body or {}).get("id", ""))
    if not ID_RE.match(rid):
        return 400, {"error": "bad_id"}
    L.append_jsonl(_file(), {"id": rid, "deleted": True, "t": round(now)})
    return 200, {"ok": True}


def nearby(lat, lon, now=None):
    now = now or time.time()
    out = [dict(id=r["id"], kind=r["kind"], t=r["t"], lat=r["lat"], lon=r["lon"])
           for r in _rows(now - SERVE_S) if L.km(lat, lon, r["lat"], r["lon"]) <= SERVE_KM]
    return {"reports": out[-50:]}


def hour_truth(lat, lon, hour_start):
    """For learner.observe: (wet, source) from reports near the place in the hour before
    `hour_start` (+7 min, like the METARs), or None when nobody reported. Any wet report makes the
    hour wet (it rained at some point); only dry reports make it dry."""
    rows = [r for r in _rows(hour_start - 3600)
            if r["t"] <= hour_start + 420 and L.km(lat, lon, r["lat"], r["lon"]) <= TRUTH_KM]
    if not rows:
        return None
    wet = [r for r in rows if r["kind"] not in DRY]
    if wet:
        return 1, f"{len(wet)} report{'s' if len(wet) > 1 else ''}: {wet[-1]['kind']}"
    return 0, f"{len(rows)} report{'s' if len(rows) > 1 else ''}: {rows[-1]['kind']}"


def trim(now=None):
    now = now or time.time()
    L.trim_jsonl(_file(), now - KEEP_DAYS * 86400)


def handle(method, path, query, body, client="", now=None):
    """relay.py's hook. `query` is a dict of lists (urllib.parse.parse_qs) or of strings; `body`
    the request body as bytes, str or an already-parsed dict. Returns (status, dict) or None."""
    path = path.split("?")[0].rstrip("/")
    if path not in ("/v1/report", "/v1/reports"):
        return None
    if isinstance(body, (bytes, bytearray)):
        body = body.decode("utf-8", "replace")
    if isinstance(body, str):
        try:
            body = json.loads(body) if body.strip() else {}
        except ValueError:
            return 400, {"error": "bad_json"}
    if path == "/v1/reports" and method == "GET":
        q = {k: (v[0] if isinstance(v, list) else v) for k, v in (query or {}).items()}
        try:
            return 200, nearby(float(q["lat"]), float(q["lon"]), now)
        except (KeyError, ValueError):
            return 400, {"error": "lat_lon_required"}
    if path == "/v1/report" and method == "POST":
        return add(body or {}, client, now)
    if path == "/v1/report" and method == "DELETE":
        return withdraw(body, now)
    return 405, {"error": "method_not_allowed"}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "near":
        print(json.dumps(nearby(float(sys.argv[2]), float(sys.argv[3])), indent=1))
    elif cmd == "trim":
        trim()
    else:
        sys.exit("usage: reports.py near LAT LON | trim")
