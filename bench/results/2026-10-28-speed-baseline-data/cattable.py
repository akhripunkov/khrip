"""Таблица категорий из categories.txt (вывод catz.py для нескольких дампов): строки — категории, столбцы — дампы, тыс. инструкций на запрос."""
import collections
import re
import sys

cols = []
data = collections.defaultdict(dict)
tot = {}
cur = None
for line in open(sys.argv[1]):
    m = re.match(r"== (\S+)", line)
    if m:
        cur = m.group(1)
        cols.append(cur)
        continue
    m = re.match(r"всего ([\d,]+)", line)
    if m:
        tot[cur] = int(m.group(1).replace(",", ""))
        continue
    m = re.match(r"\s*([\d,]+)\s+[\d.]+%\s+(.*)$", line)
    if m:
        data[m.group(2).strip()][cur] = int(m.group(1).replace(",", ""))
want = sys.argv[2].split(",") if len(sys.argv) > 2 else cols
order = sorted(data, key=lambda k: -max(data[k].get(c, 0) for c in want))
print("| Категория | " + " | ".join(want) + " |")
print("|---|" + "---:|" * len(want))
for k in order:
    if max(data[k].get(c, 0) for c in want) < 500:
        continue
    cells = []
    for c in want:
        v = data[k].get(c, 0)
        cells.append(f"{v / 1000:,.1f} ({100 * v / tot[c]:.0f} %)".replace(",", " ").replace(".", ","))
    print(f"| {k} | " + " | ".join(cells) + " |")
print("| **всего** | " + " | ".join(f"**{tot[c] / 1000:,.0f}**".replace(",", " ") for c in want) + " |")
