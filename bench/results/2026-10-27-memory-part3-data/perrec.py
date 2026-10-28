#!/usr/bin/env python3
"""Live bytes per record: Khrip (live by idle GC) vs Go (HeapAlloc after GC).
usage: perrec.py <go-attr-dir> <variant>=<attr-dir> ...
Records = Go heap objects after GC / Go objects per record (baseline report)."""
import re, sys, os
OBJ = {"inventory": 3.0, "bank": 1.0, "polls": 1.0, "notes": 4.0, "shortener": 3.0, "ratelimit": 2.0}
SC = ["inventory", "bank", "polls", "notes", "shortener", "ratelimit"]
MB = 1048576.0
def go(d, sc):
    f = os.path.join(d, sc, "go", "summary.txt")
    if not os.path.exists(f): return None
    t = open(f).read()
    m = re.search(r"after-gc heap_alloc=(\d+) .*?heap_objects=(\d+)", t)
    return (int(m.group(1)), int(m.group(2))) if m else None
def kh(d, sc):
    f = os.path.join(d, sc, "khrip", "summary.txt")
    if not os.path.exists(f): return None
    t = open(f).read()
    m = re.search(r"live by GC ([0-9.]+) MB; gc \d+ \(idle\): heap [0-9.]+->[0-9.]+ MB, live [0-9.]+ MB \((\d+) obj", t)
    r = re.search(r"Requests/sec:\s+([0-9.]+)", t)
    return (float(m.group(1)) * MB, int(m.group(2)), float(r.group(1)) if r else 0) if m else None
gdir = sys.argv[1]
vars_ = [a.split("=", 1) for a in sys.argv[2:]]
print("| Scenario | records | Go B/rec | " + " | ".join(f"{v}: B/rec (obj/rec), Khrip/Go" for v, _ in vars_) + " |")
print("|---|---:|---:|" + "---:|" * len(vars_))
for sc in SC:
    g = go(gdir, sc)
    if not g: continue
    rec = g[1] / OBJ[sc]
    cells = []
    for v, d in vars_:
        k = kh(d, sc)
        if not k:
            cells.append("—"); continue
        cells.append(f"{k[0]/rec:.0f} ({k[1]/rec:.1f}), {k[0]/g[0]:.2f}")
    print(f"| {sc} | {rec/1e6:.2f} M | {g[0]/rec:.0f} | " + " | ".join(cells) + " |")
