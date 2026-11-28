#!/usr/bin/env python3
"""Add tools/score_short_range.py's weights to the app's table, only where they win.

For each region and lead band (0-2, 3-5, 6-11 h) the short-range weights are used only where,
held out by airport, they beat what the app does now (the day-0 row) by at least 1%; a band that
doesn't win keeps the day-0 row. A region where no band wins gets no short-range weights.
Then re-run gen_blend_regions.py on the table to regenerate the Swift.

  python3 merge_short_range.py short-range-weights.json short-range-report.json
  python3 gen_blend_regions.py ../Packages/WeatherCore/blend-regions.json
"""
import json, os, sys

from gen_blend_regions import ORDER, ROOT

GAIN = 0.99


def main():
    weights = json.load(open(sys.argv[1]))["regions"]
    report = json.load(open(sys.argv[2]))["regions"]
    path = os.path.join(ROOT, "blend-regions.json")
    table = json.load(open(path))
    for r in table["regions"] + [table["global"]]:
        rid = r["id"]
        bands = report.get(rid, {}).get("bands", [])
        chosen = weights.get(rid, [])
        out, wins = [], 0
        for b, band in enumerate(bands):
            new, now = band.get("held_out_chosen"), band.get("held_out_app_now")
            if new is not None and now is not None and new < now * GAIN and b < len(chosen):
                out.append(chosen[b])
                wins += 1
                print(f"{rid} band {b}: {now} -> {new} (short-range weights)")
            else:
                out.append(r["byDay"][0])
                print(f"{rid} band {b}: {now} vs {new} (keeps day 0)")
        if wins and len(out) == 3:
            r["shortRange"] = out
            used = {m for d in out for m in d}
            r["models"] = [m for m in ORDER if m in set(r["models"]) | used]
        else:
            r.pop("shortRange", None)
    with open(path, "w") as f:
        json.dump(table, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
