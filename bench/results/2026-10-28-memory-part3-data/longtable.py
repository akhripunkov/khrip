#!/usr/bin/env python3
"""longtable.py <base.tsv> <fin.tsv> [<gapsdir-base> <gapsdir-fin>]: 10-minute runs, base vs final, with Go peaks."""
import csv, sys, os
GO = {"bank": 3366.7, "inventory": 2143.6, "shortener": 918.1, "notes": 1077.0, "polls": 1673.9}
def rd(f):
    d = {}
    if not os.path.exists(f):
        return d
    for r in csv.DictReader(open(f), delimiter="\t"):
        d[(r["scenario"], r["variant"])] = r
    return d
b, f = rd(sys.argv[1]), rd(sys.argv[2])
def gaps(root, sc):
    if not root:
        return "—"
    n = big = 0; mx = 0.0
    for k in ("gaps.1", "gaps.2"):
        p = os.path.join(root, sc, "khrip", k)
        if os.path.exists(p):
            for line in open(p):
                v = float(line.split()[1]); n += 1; mx = max(mx, v); big += v >= 100
    return f"{big} / {mx:.0f}"
gb = sys.argv[3] if len(sys.argv) > 3 else None
gf = sys.argv[4] if len(sys.argv) > 4 else None
print("| Сценарий | вариант | пик, МБ (доля Go) | среднее за 5 мин | живое в конце | сборок (в замере) | мкс/запрос | p99, мс | p99,9 | max | зонд, max мс | щели wrk2 ≥ 100 мс / max |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for sc in ["bank", "inventory", "shortener", "notes", "polls"]:
    for name, d, gr in (("d09a8f1", b, gb), ("часть 3", f, gf)):
        r = d.get((sc, "khrip"))
        if not r:
            continue
        pk = float(r["rss_peak_mb"])
        print(f"| {sc} | {name} | {pk:.1f} ({pk / GO[sc]:.2f}) | {float(r['rss_mean_last300_mb']):.1f} | {r['live_end_mb']} | {r['gc_total']} ({r['gc_in_run']}) | {r['cpu_us_per_req']} | {r['p99_ms']} | {r['p999_ms']} | {r['max_ms']} | {r['probe_max_ms']} | {gaps(gr, sc)} |")
    print(f"| {sc} | Go (часть 1b) | {GO[sc]:.1f} | | | | | | | | | |")
