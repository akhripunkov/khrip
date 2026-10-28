"""Время процессора по категориям из perf record (-g, cpu-clock).

    python3 perfcat.py khrip <perf.data> <разметка catz> <мкс процессора на запрос>
    python3 perfcat.py csharp <perf.data> - <мкс процессора на запрос>

Khrip: каждый отсчёт относится к категории по той же разметке, что у catz.py:
от листа вверх до первой размеченной функции (fn, own — только лист); в
обработчике маршрута — по диапазону адреса возврата (range, rcall). Ядро —
отдельной категорией. C#: по имени листа (JIT встраивает лямбды и LINQ в метод
обработчика, поэтому он — отдельная категория), плюс доля отсчётов внутри
обработчика целиком (без записи JSON, которая идёт после него).
Мкс на запрос = доля × процессор на запрос из того же прогона (cpu_us.txt).
"""
import collections
import re
import subprocess
import sys

lang, data, spec, cpu_us = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
PERF = "/usr/lib/linux-tools-6.8.0-147/perf"
out = subprocess.run([PERF, "script", "-i", data, "-F", "ip,sym,dso"], capture_output=True, text=True).stdout

samples = []
cur = []
for line in out.splitlines():
    line = line.strip()
    if not line:
        if cur:
            samples.append(cur)
            cur = []
        continue
    m = re.match(r"([0-9a-f]+) (.*) \((.*)\)$", line)
    if not m:
        continue
    cur.append((int(m.group(1), 16), m.group(2), m.group(3)))
if cur:
    samples.append(cur)


def strip_off(sym):
    return re.sub(r"\+0x[0-9a-f]+$", "", sym)


cats = collections.Counter()
extra = collections.Counter()

if lang == "khrip":
    fixed, own, helpers, ranges, rcalls = {}, {}, set(), collections.defaultdict(list), collections.defaultdict(list)
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

    def classify(fr):
        if fr[0][2].startswith("[kernel"):
            return "ядро (сеть, планировщик, системные вызовы)"
        for i, (addr, sym, dso) in enumerate(fr):
            f = strip_off(sym)
            if f in helpers:
                continue
            if f in ranges:
                a = addr if i == 0 else addr - 1
                if i > 0:
                    callee = strip_off(fr[i - 1][1])
                    for lo, hi, cal, cat in rcalls.get(f, ()):
                        if lo <= a < hi and cal == callee:
                            return cat
                for lo, hi, cat in ranges[f]:
                    if lo <= a < hi:
                        return cat
                continue
            if f in fixed:
                return fixed[f]
            if f in own and i == 0:
                return own[f]
        return default

    for fr in samples:
        cats[classify(fr)] += 1
        names = [strip_off(s) for _, s, _ in fr]
        if any(n.startswith("__route_") for n in names):
            if "__reply" not in names:
                extra["обработчик целиком, без JSON ответа"] += 1
else:
    rules = [
        (r"^\[k\]|kernel", "ядро (сеть, планировщик, системные вызовы)"),
        (r"Program\+<>c__DisplayClass|<Main>\$", "обработчик (со встроенными лямбдами и LINQ)"),
        (r"ArraySortHelper|EnumerableSorter|OrderedIterator|OrderedEnumerable|CompareOrdinal|Comparer`", "сортировка (OrderBy)"),
        (r"IndexOfOrdinalIgnoreCase|EqualsIgnoreCase|OrdinalCasing|Ordinal::", "Contains без учёта регистра"),
        (r"GroupBy|Lookup`|Grouping`", "GroupBy (/categories)"),
        (r"System\.Linq", "LINQ: итераторы Where/Select/ToList"),
        (r"System\.Text\.Json|Utf8JsonWriter|Encodings\.Web|System\.Number|FormatFloat|Utf8Utility|Dragon|Grisu", "JSON: запись ответа и числа"),
        (r"AspNetCore|Kestrel|System\.IO\.Pipelines|System\.Net|Sockets|Http", "HTTP: Kestrel, ASP.NET Core"),
        (r"List`1|SpanHelpers|Buffer::|Array::|Memmove", "коллекции и копирование"),
    ]

    def classify(fr):
        addr, sym, dso = fr[0]
        if dso.startswith("[kernel"):
            return rules[0][1]
        for rx, cat in rules[1:]:
            if re.search(rx, sym):
                return cat
        if "libcoreclr" in dso or sym.startswith("stub ") or "CastHelpers" in sym or "VirtualDispatch" in sym or "libclrjit" in dso:
            return "среда .NET: GC, выделение, барьеры, заглушки"
        if "libc.so" in dso or "ld-linux" in dso:
            return "libc (memset, мьютексы)"
        return "прочее"

    for fr in samples:
        cats[classify(fr)] += 1
        if any(re.search(r"Program\+<>c__DisplayClass", s) for _, s, _ in fr):
            extra["обработчик целиком, без JSON ответа"] += 1

n = len(samples)
print(f"отсчётов {n}, процессор на запрос {cpu_us} мкс")
for k, v in cats.most_common():
    print(f"{100 * v / n:6.1f}%  {cpu_us * v / n:7.1f} мкс  {k}")
for k, v in extra.items():
    print(f"[{100 * v / n:6.1f}%  {cpu_us * v / n:7.1f} мкс  {k}]")
