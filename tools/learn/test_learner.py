#!/usr/bin/env python3
"""Offline checks of the learning maths (no network): python3 test_learner.py"""
import json, math, os, random, sys, tempfile

os.environ["LEARN_DATA_DIR"] = tempfile.mkdtemp()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import learner as L  # noqa: E402

NOW = 1795000000 - 1795000000 % 86400 + 7 * 60   # 00:07 UTC


def synth(cell, bias_fn, days=30, pop_true=0.2, pop_fc=0.4, seed=1):
    rnd = random.Random(seed)
    key = cell.replace(",", "_")
    truth = {}
    for h in range(days * 24 + 1):
        t = NOW - days * 86400 + h * 3600 - 7 * 60
        truth[t] = (5 + 4 * math.sin(2 * math.pi * (t % 86400) / 86400) + rnd.gauss(0, 0.7),
                    1 if rnd.random() < pop_true else 0)
        L.append_jsonl(L.path("obs", key + ".jsonl"),
                       {"t": t, "temp": round(truth[t][0], 1), "temp_src": "station X 3 km",
                        "wet": truth[t][1], "wet_src": "radar"})
    for s in range(days * 8):
        issued = NOW - days * 86400 + s * 10800
        hours = {}
        for lead in range(1, 121):
            v = int(issued - issued % 3600 + lead * 3600)
            if v not in truth:
                continue
            temp = truth[v][0] + bias_fn(v) + rnd.gauss(0, 1.0)
            hours[str(v)] = [round(temp, 2), 0.3, pop_fc]
        L.append_jsonl(L.path("fc", key + ".jsonl"), {"t": issued, "region": "na_east", "hours": hours})


def test_warm_nights_are_learned_and_proven():
    cell = L.cell_of(43.51, -79.88)
    L.lookup(43.51, -79.88, now=NOW)
    night = lambda v: 1.5 if (v % 86400) // 3600 in range(3, 12) else 0.0   # noqa: E731
    synth(cell, night)
    out = L.learn(cell, NOW)
    t = out["temperature"]
    assert t["enabled"], t
    assert t["mae_learned"] < t["mae_raw"] * 0.97, t
    assert max(t["bias_3h"][1:4]) > 0.8, t["bias_3h"]      # 03-12 UTC (night in Ontario) warm
    assert abs(t["bias_3h"][6]) < 0.5, t["bias_3h"]        # afternoon about right
    r = out["rain"]
    assert r["enabled"], r                                 # chance 40% but rains 20% of hours
    assert 0.5 <= r["pop_factor"] < 0.75, r
    assert L.lookup(43.51, -79.88, register=False, now=NOW)["status"] == "correcting"


def test_no_bias_means_nothing_switched_on():
    cell = L.cell_of(51.5, -0.1)
    synth(cell, lambda v: 0.0, pop_true=0.3, pop_fc=0.3, seed=2)
    out = L.learn(cell, NOW)
    assert not out["temperature"]["enabled"], out["temperature"]
    assert out["temperature"]["bias_3h"] == [0.0] * 8
    assert not out["rain"]["enabled"], out["rain"]
    assert out["rain"]["pop_factor"] == 1.0


def test_too_little_history_waits():
    cell = L.cell_of(-33.9, 151.2)
    synth(cell, lambda v: 2.0, days=6, seed=3)
    out = L.learn(cell, NOW)
    assert out["status"] == "learning" and not out["temperature"]["enabled"], out


def test_bias_interpolation_matches_app():
    bins = [1.0, 0, 0, 0, -1.0, 0, 0, 0]
    assert abs(L.bias_at(bins, 1.5 * 3600) - 1.0) < 1e-9
    assert abs(L.bias_at(bins, 0) - 0.5) < 1e-9           # midnight between bin 7 and bin 0
    assert abs(L.bias_at(bins, 13.5 * 3600) + 1.0) < 1e-9


def test_unknown_place_says_learning():
    out = L.lookup(10.0, 10.0, register=False)
    assert out["status"] == "learning" and out["temperature"]["enabled"] is False


def test_pinned_place_keeps_pin_when_app_opens_there():
    places = {"200,200": {"first_seen": 0, "last_seen": 0, "pinned": True}}
    L.save(L.path("places.json"), places)
    L.lookup(20.0, 20.0, register=True, now=10_000_000)
    p = L.load(L.path("places.json"), {})["200,200"]
    assert p["pinned"] is True and p["last_seen"] == 10_000_000


def test_family_reports_are_served_withdrawn_and_used_as_rain_truth():
    import reports as R
    t0 = NOW - 7 * 60                       # top of the hour
    assert R.handle("POST", "/v1/report", {}, b'{"id":"aaaaaaaa-1","kind":"drizzle","t":%d,"lat":43.513,"lon":-79.882}' % (t0 - 1200), "x", now=t0)[0] == 200
    assert R.add({"id": "bad id!", "kind": "rain", "lat": 1, "lon": 1})[0] == 400
    assert R.add({"id": "bbbbbbbb-2", "kind": "hail", "lat": 1, "lon": 1})[0] == 400
    R.add({"id": "cccccccc-3", "kind": "cloudy", "t": t0 - 600, "lat": 43.45, "lon": -79.68}, now=t0)
    near = R.nearby(43.51, -79.88, now=t0)["reports"]
    assert [r["id"] for r in near] == ["aaaaaaaa-1"], near            # Oakville is 17 km away
    # Learner: the drizzle report makes Milton's hour wet, Oakville's cloudy report makes it dry.
    assert R.hour_truth(43.5, -79.9, t0)[0] == 1
    assert R.hour_truth(43.5, -79.7, t0)[0] == 0
    assert R.hour_truth(45.0, -75.0, t0) is None
    R.handle("DELETE", "/v1/report", {}, '{"id":"aaaaaaaa-1"}', now=t0)
    assert R.nearby(43.51, -79.88, now=t0)["reports"] == []
    assert R.hour_truth(43.5, -79.9, t0) is None
    assert R.handle("GET", "/v1/reports", {"lat": ["43.5"], "lon": ["-79.9"]}, b"")[0] == 200
    assert R.handle("GET", "/v1/other", {}, b"") is None
    for i in range(R.PER_CLIENT_HOUR):
        R.add({"id": f"dddddddd-{i}", "kind": "rain", "lat": 1, "lon": 1}, client="spam", now=t0)
    assert R.add({"id": "eeeeeeee-1", "kind": "rain", "lat": 1, "lon": 1}, client="spam", now=t0)[0] == 429


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
