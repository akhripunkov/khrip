"""Инструкции на запрос по категориям (файл callgrind с --dump-instr=yes).

    python3 catz.py <cg-файл> <бинарник с символами> <разметка> [запросов]

Запросов — по умолчанию вызовы __dispatch в файле. Разметка — строки:

    fn   <функция> <категория>        вся функция со всем, что она вызывает, — категория
                                      (если вызванная функция не размечена сама)
    own  <функция> <категория>        только собственные инструкции функции; вызовы
                                      идут по своим правилам
    help <функция>                    помощник: его инструкции — категории того, кто
                                      вызвал (в том месте вызова)
    range <функция> <от> <до> <категория>
                                      команды функции с адресами [от, до) и вызовы из
                                      них — категория (для обработчиков маршрутов, где
                                      циклы и лямбды встроены)
    rcall <функция> <от> <до> <вызываемая> <категория>
                                      вызовы этой функции из [от, до) — категория
                                      (поверх range и правил вызываемой)
    default <категория>               всё, что не размечено

Стоимость вызова распределяется по категориям вызванной функции пропорционально
её общей раскладке (как в gprof): помощник, вызванный из разных мест, делится по
местам вызова точно, а его собственные вызовы — пропорционально.
"""
import collections
import subprocess
import sys

cg, binp, spec = sys.argv[1:4]
reqs = int(sys.argv[4]) if len(sys.argv) > 4 else None

self_at = collections.defaultdict(collections.Counter)  # fn -> addr -> cost
edges = collections.defaultdict(collections.Counter)  # fn -> (site, callee) -> cost
fn = cfn = None
after_calls = False
total = 0
dispatch_calls = 0
for line in open(cg):
    if line.startswith("fn="):
        fn = line[3:].strip()
        continue
    if line.startswith("cfn="):
        cfn = line[4:].strip()
        continue
    if line.startswith("calls="):
        after_calls = True
        if cfn == "__dispatch":
            dispatch_calls += int(line[6:].split()[0])
        continue
    if line.startswith("summary:"):
        total = int(line.split()[1])
        continue
    if not line or line[0] not in "0+-*":
        continue
    parts = line.split()
    if len(parts) < 3:
        continue
    addr = int(parts[0], 16)
    cost = int(parts[2])
    if after_calls:
        edges[fn][(addr, cfn)] += cost
        after_calls = False
    else:
        self_at[fn][addr] += cost
if reqs is None:
    reqs = dispatch_calls

fixed = {}
own = {}
helpers = set()
ranges = collections.defaultdict(list)
rcalls = collections.defaultdict(list)
default = "прочее"
for line in open(spec):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    if line.startswith("rcall"):
        p = line.split(None, 5)
        rcalls[p[1]].append((int(p[2], 16), int(p[3], 16), p[4], p[5]))
        continue
    p = line.split(None, 4) if line.startswith("range") else line.split(None, 2)
    if p[0] == "fn":
        fixed[p[1]] = p[2]
    elif p[0] == "own":
        own[p[1]] = p[2]
    elif p[0] == "help":
        helpers.add(p[1])
    elif p[0] == "range":
        ranges[p[1]].append((int(p[2], 16), int(p[3], 16), p[4]))
    elif p[0] == "default":
        default = line.split(None, 1)[1]

INH = None  # «как у вызвавшего»


def site_cat(f, addr):
    for a, b, c in ranges.get(f, ()):
        if a <= addr < b:
            return c
    return None


# Компоненты сильной связности графа вызовов (рекурсия: __json_enc'2 ↔
# __json_enc_list'2): рёбра внутри компоненты не считаются — их включительная
# стоимость уже есть у членов компоненты (как циклы в gprof).
nodes = set(self_at) | set(edges)
for f in edges:
    for (_, g) in edges[f]:
        nodes.add(g)
succ = {f: {g for (_, g) in edges[f]} for f in nodes}
comp = {}
index = {}
low = {}
stack = []
on = set()
counter = [0]
sys.setrecursionlimit(100000)


def tarjan(v):
    index[v] = low[v] = counter[0]
    counter[0] += 1
    stack.append(v)
    on.add(v)
    for w in succ.get(v, ()):
        if w not in index:
            tarjan(w)
            low[v] = min(low[v], low[w])
        elif w in on:
            low[v] = min(low[v], index[w])
    if low[v] == index[v]:
        members = []
        while True:
            w = stack.pop()
            on.discard(w)
            members.append(w)
            if w == v:
                break
        for w in members:
            comp[w] = v


for v in nodes:
    if v not in index:
        tarjan(v)
members = collections.defaultdict(list)
for v, c in comp.items():
    members[c].append(v)

memo = {}


def label(f):
    if f in helpers:
        return INH
    return fixed.get(f) or own.get(f) or INH


def profile(c0):
    """Раскладка включительной стоимости компоненты c0 по категориям; INH — «как у вызвавшего»."""
    if c0 in memo:
        return memo[c0]
    prof = collections.Counter()
    for f in members[c0]:
        mine = label(f)
        for addr, c in self_at[f].items():
            cat = site_cat(f, addr) if f in ranges else None
            prof[cat if cat is not None else mine] += c
        for (addr, g), c in edges[f].items():
            if comp[g] == c0:
                continue
            forced = None
            for a, b, callee, cat in rcalls.get(f, ()):
                if a <= addr < b and callee == g:
                    forced = cat
            sub = profile(comp[g])
            tot = sum(sub.values())
            if forced is not None:
                ctx = forced
            else:
                ctx = site_cat(f, addr) if f in ranges else None
                if ctx is None:
                    # вызовы размеченной целиком функции — её категория; у own,
                    # помощников и неразмеченных — как у того, кто вызвал их самих
                    ctx = fixed.get(f, INH)
                if g in fixed and g not in helpers:
                    ctx = fixed[g]
            if tot == 0:
                prof[ctx] += c
                continue
            for k, v in sub.items():
                prof[ctx if k is INH else k] += c * v / tot
    memo[c0] = prof
    return prof


# корни: функции, которых никто не вызывает (по рёбрам этого файла)
called = set()
for f in edges:
    for (_, g) in edges[f]:
        if comp[g] != comp[f]:
            called.add(comp[g])
roots = {comp[f] for f in nodes} - called
result = collections.Counter()
for r in roots:
    for k, v in profile(r).items():
        result[default if k is INH else k] += v
s = sum(result.values())
print(f"всего {total / reqs:,.0f} инструкций на запрос ({reqs} запросов; разложено {s / reqs:,.0f})")
for k, v in sorted(result.items(), key=lambda x: -x[1]):
    print(f"{v / reqs:12,.0f}  {100 * v / s:5.1f}%  {k}")
