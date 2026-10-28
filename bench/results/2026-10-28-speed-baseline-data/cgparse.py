"""Разбор файла callgrind (--compress-strings=no --compress-pos=no, positions: instr line).

    python3 cgparse.py <cg-файл> <запросов> [self|incl|calls ФУНКЦИЯ|instr ФУНКЦИЯ|cat КАТЕГОРИИ]

self  — собственные инструкции функций на запрос (по убыванию)
incl  — включительные (свои + вызовы) на запрос
calls ФУНКЦИЯ — кого вызывает функция: число вызовов и включительные на запрос
instr ФУНКЦИЯ — собственные инструкции по адресам (для разметки цикла по дизассемблеру)
cat ФАЙЛ — свести собственные инструкции по категориям: строки файла «функция<TAB>категория»
           (функции без строки — «прочее»)
"""
import collections
import sys

path, reqs = sys.argv[1], int(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else "self"
arg = sys.argv[4] if len(sys.argv) > 4 else None

self_cost = collections.Counter()
call_cost = collections.defaultdict(collections.Counter)
call_count = collections.defaultdict(collections.Counter)
instr = collections.defaultdict(collections.Counter)
fn = None
cfn = None
after_calls = False
calls_n = 0
total = 0
for line in open(path):
    if line.startswith("fn="):
        fn = line[3:].strip()
        continue
    if line.startswith("cfn="):
        cfn = line[4:].strip()
        continue
    if line.startswith("calls="):
        after_calls = True
        calls_n = int(line[6:].split()[0])
        continue
    if line.startswith("summary:"):
        total = int(line.split()[1])
        continue
    if not line or not (line[0] == "0" or line[0] == "+" or line[0] == "-" or line[0] == "*"):
        continue
    parts = line.split()
    if len(parts) < 3:
        continue
    cost = int(parts[2])
    if after_calls:
        call_cost[fn][cfn] += cost
        call_count[fn][cfn] += calls_n
        after_calls = False
        continue
    self_cost[fn] += cost
    instr[fn][parts[0]] += cost


def per(x):
    return x / reqs


if mode == "self":
    print(f"всего {per(total):,.0f} на запрос")
    for f, c in self_cost.most_common(60):
        print(f"{per(c):12,.0f}  {100 * c / total:5.1f}%  {f}")
elif mode == "incl":
    incl = {f: self_cost[f] + sum(call_cost[f].values()) for f in set(self_cost) | set(call_cost)}
    for f, c in sorted(incl.items(), key=lambda x: -x[1])[:70]:
        print(f"{per(c):12,.0f}  {100 * c / total:5.1f}%  {f}")
elif mode == "calls":
    print(f"{arg}: своих {per(self_cost[arg]):,.0f}")
    for g, c in call_cost[arg].most_common():
        print(f"{per(c):12,.0f}  вызовов {call_count[arg][g] / reqs:8.1f}  {g}")
elif mode == "instr":
    for a, c in sorted(instr[arg].items(), key=lambda x: int(x[0], 16)):
        print(f"{a} {per(c):10.1f}")
elif mode == "cat":
    cats = {}
    for line in open(arg):
        line = line.strip()
        if line and not line.startswith("#"):
            f, c = line.split("\t")
            cats[f] = c
    by = collections.Counter()
    unknown = collections.Counter()
    for f, c in self_cost.items():
        k = cats.get(f, "прочее")
        by[k] += c
        if k == "прочее":
            unknown[f] += c
    print(f"всего {per(total):,.0f} на запрос")
    for k, c in by.most_common():
        print(f"{per(c):12,.0f}  {100 * c / total:5.1f}%  {k}")
    print("-- прочее:")
    for f, c in unknown.most_common(15):
        print(f"{per(c):12,.0f}  {f}")

if mode == "tree":
    # дерево вызовов от функции arg: включительные на запрос (порог — 0,2 % всего)
    seen = set()

    def walk(f, depth, cost):
        print(f"{'  ' * depth}{per(cost):12,.0f}  {f}  (своих {per(self_cost[f]):,.0f})")
        if f in seen or depth > 12:
            return
        seen.add(f)
        for g, c in call_cost[f].most_common():
            if c < total * 0.002:
                continue
            walk(g, depth + 1, c)
        seen.discard(f)

    incl = self_cost[arg] + sum(call_cost[arg].values())
    walk(arg, 0, incl)
