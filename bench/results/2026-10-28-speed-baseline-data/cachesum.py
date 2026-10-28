"""Модель кеша callgrind (--cache-sim=yes): промахи на запрос по функциям.

    python3 cachesum.py <cg-файл> [функций]

Это модель (L1 и последний уровень по CPUID машины, без предвыборки), а не
счётчики процессора. Запросов — вызовы __dispatch в файле.
"""
import collections
import sys

path = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 12
events = []
self_c = collections.defaultdict(lambda: None)
fn = cfn = None
after_calls = False
reqs = 0
for line in open(path):
    if line.startswith("events:"):
        events = line.split()[1:]
        continue
    if line.startswith("fn="):
        fn = line[3:].strip()
        continue
    if line.startswith("cfn="):
        cfn = line[4:].strip()
        continue
    if line.startswith("calls="):
        after_calls = True
        if cfn == "__dispatch":
            reqs += int(line[6:].split()[0])
        continue
    if not line or line[0] not in "0":
        continue
    p = line.split()
    if after_calls:
        after_calls = False
        continue
    vals = [int(x) for x in p[2:]] + [0] * (len(events) - len(p[2:]))
    cur = self_c[fn]
    if cur is None:
        self_c[fn] = vals
    else:
        for i, v in enumerate(vals):
            cur[i] += v
tot = [0] * len(events)
for v in self_c.values():
    for i, x in enumerate(v):
        tot[i] += x
idx = {e: i for i, e in enumerate(events)}
print(f"запросов {reqs}; на запрос: " + ", ".join(f"{e} {tot[i] / reqs:,.0f}" for i, e in enumerate(events)))
for key in ("D1mr", "DLmr"):
    if key not in idx:
        continue
    k = idx[key]
    print(f"-- по {key} (на запрос):")
    for f, v in sorted(self_c.items(), key=lambda x: -x[1][k])[:top]:
        print(f"{v[k] / reqs:10,.1f}  Ir {v[idx['Ir']] / reqs:10,.0f}  {f}")
