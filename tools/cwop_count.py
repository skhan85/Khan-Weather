#!/usr/bin/env python3
"""Listen to the free APRS-IS feed for a while and list the CWOP weather stations near Milton,
with their distance and last temperature, to see whether CWOP could add stations to "now"."""
import math, re, socket, sys, time

LAT, LON, KM, SECONDS = 43.513, -79.882, 25, int(sys.argv[1]) if len(sys.argv) > 1 else 900

def km(lat, lon):
    p = math.pi / 180
    a = math.sin((lat - LAT) * p / 2) ** 2 + math.cos(LAT * p) * math.cos(lat * p) * math.sin((lon - LON) * p / 2) ** 2
    return 2 * 6371 * math.asin(math.sqrt(a))

POS = re.compile(r"(\d{2})(\d{2}\.\d{2})([NS]).(\d{3})(\d{2}\.\d{2})([EW])")
TEMP = re.compile(r"t(-?\d{2,3})")
seen = {}
buf, end = b"", time.time() + SECONDS
s = None
while time.time() < end:
    if s is None:
        try:
            s = socket.create_connection(("rotate.aprs2.net", 14580), timeout=30)
            s.sendall(f"user KHANWX pass -1 vers KhanWeatherProbe 0.2 filter r/{LAT}/{LON}/{KM}\r\n".encode())
            s.settimeout(30)
        except OSError as e:
            print("connect failed:", e); s = None; time.sleep(10); continue
    try:
        d = s.recv(4096)
    except socket.timeout:
        continue
    if not d:
        print("server closed the connection; reconnecting"); s = None; time.sleep(5); continue
    buf += d
    *lines, buf = buf.split(b"\n")
    for raw in lines:
        line = raw.decode(errors="replace").strip()
        if line.startswith("#"):
            print(line)
            continue
        if ":" not in line:
            continue
        call, body = line.split(">", 1)[0], line.split(":", 1)[1]
        m = POS.search(body)
        if not m:
            continue
        lat = (int(m[1]) + float(m[2]) / 60) * (1 if m[3] == "N" else -1)
        lon = (int(m[4]) + float(m[5]) / 60) * (1 if m[6] == "E" else -1)
        t = TEMP.search(body[m.end():]) if "_" in body[m.end():m.end() + 2] else None
        seen[call] = (round(km(lat, lon), 1), round((int(t[1]) - 32) * 5 / 9, 1) if t else None)
weather = sorted((v[0], c, v[1]) for c, v in seen.items() if v[1] is not None)
print(f"{len(seen)} APRS stations heard within {KM} km in {SECONDS // 60} min; {len(weather)} weather stations:")
for d, c, t in weather:
    print(f"  {c:12s} {d:5.1f} km  {t} °C")
