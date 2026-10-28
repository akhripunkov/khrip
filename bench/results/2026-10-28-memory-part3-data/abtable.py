#!/usr/bin/env python3
"""abtable.py <A.tsv> <B.tsv>: per scenario, B/A medians over rounds (rps, CPU µs per request)."""
import csv, statistics, sys
def rd(f):
    d = {}
    for row in csv.DictReader(open(f), delimiter="\t"):
        d.setdefault(row["scenario"], []).append(row)
    return d
a, b = rd(sys.argv[1]), rd(sys.argv[2])
print("| scenario | rounds | rps A (median) | rps B (median) | B/A rps (median of pairs) | CPU µs/req A | CPU µs/req B | B/A CPU | p99 A / B, ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
order = ["shortener", "bank", "notes", "login", "ratelimit", "catalog", "patch", "inventory", "polls", "bookings", "ledger", "shop", "tracker"]
for sc in order:
    ra, rb = a.get(sc, []), b.get(sc, [])
    n = min(len(ra), len(rb))
    if n == 0:
        continue
    fa = lambda rows, k: [float(r[k]) for r in rows[:n]]
    rpsA, rpsB = fa(ra, "rps"), fa(rb, "rps")
    cpuA, cpuB = fa(ra, "cpu_us_per_req"), fa(rb, "cpu_us_per_req")
    p99A, p99B = fa(ra, "p99_ms"), fa(rb, "p99_ms")
    ratio = statistics.median([y / x for x, y in zip(rpsA, rpsB) if x])
    cratio = statistics.median([y / x for x, y in zip(cpuA, cpuB) if x])
    print(f"| {sc} | {n} | {statistics.median(rpsA):.0f} | {statistics.median(rpsB):.0f} | {ratio:.3f} | {statistics.median(cpuA):.2f} | {statistics.median(cpuB):.2f} | {cratio:.3f} | {statistics.median(p99A):.2f} / {statistics.median(p99B):.2f} |")
