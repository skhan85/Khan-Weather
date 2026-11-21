#!/usr/bin/env python3
"""Copy new forecast snapshots from the family relay into the log on the forecast-log branch.

Since 21 Nov 2026 the hourly logging (tools/log_forecasts.py) runs from cron on the VPS, which
GitHub's loose schedule couldn't manage (it fired about every 8 hours). The relay serves the
snapshots at /v1/forecast-log?since=<unix>; this appends those newer than the last one here.
Exits 1 when the relay can't be reached, so the workflow can log one snapshot itself instead.
"""
import json, os, sys, urllib.request

path = sys.argv[1]
relay = os.environ.get("RELAY_URL", "https://weather-relay.khanofmilton.ca")
last = 0
if os.path.exists(path):
    with open(path) as f:
        for line in f:
            try:
                last = max(last, json.loads(line)["fetched"])
            except Exception:
                pass
try:
    req = urllib.request.Request(f"{relay}/v1/forecast-log?since={last}",
                                 headers={"User-Agent": "khan-weather-forecast-log"})
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read().decode()
except Exception as e:
    print("relay unreachable:", e)
    sys.exit(1)
new = []
for line in body.splitlines():
    try:
        snap = json.loads(line)
    except Exception:
        continue
    if snap.get("fetched", 0) > last:
        new.append(json.dumps(snap, separators=(",", ":")))
with open(path, "a") as f:
    for line in sorted(new, key=lambda l: json.loads(l)["fetched"]):
        f.write(line + "\n")
print(f"copied {len(new)} snapshots from the relay")
