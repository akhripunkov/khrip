"""cgtable.py <папка cg> — команды на запрос (тыс.) по веткам и стадиям, к основе."""
import os, sys
d = sys.argv[1]
stages = ["base", "tree1", "tree2", "tree3", "tree4"]
names = {"base": "основа", "tree1": "п. 1", "tree2": "п. 2", "tree3": "п. 3", "tree4": "п. 4"}
for sc in ["catalog", "bookings"]:
    rows = {}
    order = []
    for st in stages:
        f = os.path.join(d, f"{st}-{sc}", "reqs.tsv")
        if not os.path.exists(f):
            continue
        seen = {}
        for line in open(f):
            lua, rd, rw, ipr = line.split()
            seen[lua] = seen.get(lua, 0) + 1
            key = lua if sc == "catalog" else f"{lua}@{8500 if seen[lua] == 1 else 11000}"
            if key not in order:
                order.append(key)
            rows.setdefault(key, {})[st] = int(ipr)
    print(f"\n{sc}")
    print("| ветка | " + " | ".join(names[s] for s in stages) + " | итог/основа |")
    print("|---|" + "---:|" * (len(stages) + 1))
    for k in order:
        r = rows[k]
        cells = [f"{r[s] / 1000:,.1f}".replace(",", " ") if s in r else "—" for s in stages]
        ratio = f"{r['tree4'] / r['base']:.3f}" if "tree4" in r and "base" in r else "—"
        print(f"| {k} | " + " | ".join(cells) + f" | {ratio} |")
