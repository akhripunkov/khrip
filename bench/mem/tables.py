#!/usr/bin/env python3
"""Таблицы отчёта об этапе памяти (часть 1) из сырых данных.

    tables.py rate <perf_rate.tsv>           — по сценариям: RSS пик / среднее /
                                               наклон, достигнутая частота, p99
    tables.py conn <perf_conn.tsv>           — RSS от числа соединений и наклон, КБ на соединение
    tables.py attr <папка bench/mem/out>     — раскладка RSS Khrip (снимки khrip_rss.py)
                                               и Go (MemStats) по сценариям
    tables.py attr-tsv <папка bench/mem/out> — то же построчно (TSV): сценарий,
                                               снимок, часть, МБ
    tables.py long <long.tsv>                — долгие прогоны (bench/mem/long.sh)
    tables.py timeline <папка long>          — RSS по минутам: сценарий × вариант
Печатает Markdown (или TSV) в stdout.
"""
import csv
import json
import math
import os
import re
import sys

LANGS = [("khrip", "Khrip"), ("go", "Go"), ("csharp", "C#")]
MB = 1048576.0


def rows(path):
    return list(csv.DictReader(open(path), delimiter="\t"))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return math.nan


def fmt(v, d=1):
    return "—" if math.isnan(v) else f"{v:.{d}f}"


def rate_table(path):
    rs = rows(path)
    data = {(r["scenario"], r["lang"]): r for r in rs}
    scen = []
    for r in rs:
        if r["scenario"] not in scen:
            scen.append(r["scenario"])
    print("| Сценарий | Частота | " + " | ".join(f"{n}: пик / среднее, МБ" for _, n in LANGS) + " | Khrip / Go (пик) |")
    print("|---|---:|" + "---:|" * len(LANGS) + "---:|")
    for sc in scen:
        cells = []
        for l, _ in LANGS:
            r = data.get((sc, l))
            if not r:
                cells.append("—")
                continue
            c = f"{fmt(num(r['rss_peak_mb']))} / {fmt(num(r['rss_mean_mb']))}"
            if r["behind"] != "ok":
                c += " ⚠"
            cells.append(c)
        k, g = data.get((sc, "khrip")), data.get((sc, "go"))
        ratio = num(k["rss_peak_mb"]) / num(g["rss_peak_mb"]) if k and g else math.nan
        mark = f"**{ratio:.2f}**" if ratio > 1 else f"{ratio:.2f}"
        print(f"| {sc} | {data[(sc, 'khrip')]['rate'] if (sc, 'khrip') in data else '—'} | " + " | ".join(cells) + f" | {mark} |")
    print()
    print("| Сценарий | " + " | ".join(f"{n}: достигнуто, p99 мс, наклон МБ/с" for _, n in LANGS) + " |")
    print("|---|" + "---:|" * len(LANGS))
    for sc in scen:
        cells = []
        for l, _ in LANGS:
            r = data.get((sc, l))
            if not r:
                cells.append("—")
                continue
            ach = r["achieved_rps"] + (" ⚠" if r["behind"] != "ok" else "")
            cells.append(f"{ach}; {r['p99_ms']}; {num(r['rss_slope_mb_s']):+.3f}")
        print(f"| {sc} | " + " | ".join(cells) + " |")


def conn_table(path):
    rs = rows(path)
    by = {}
    for r in rs:
        by.setdefault((r["scenario"], r["lang"]), {})[int(r["connections"])] = r
    ns = sorted({int(r["connections"]) for r in rs})
    print("| Сценарий | Язык | " + " | ".join(f"RSS при {n}, МБ" for n in ns) + " | Наклон 64→1000, КБ/соед. | Наклон 64→10000, КБ/соед. |")
    print("|---|---|" + "---:|" * len(ns) + "---:|---:|")
    for (sc, l), m in by.items():
        cells = []
        for n in ns:
            r = m.get(n)
            if not r:
                cells.append("—")
                continue
            c = r["rss_mean_mb"]
            if r["behind"] != "ok" or num(r["errors_pct"]) > 0:
                c += " ⚠"
            cells.append(c)

        def slope(a, b):
            if a in m and b in m:
                return (num(m[b]["rss_mean_mb"]) - num(m[a]["rss_mean_mb"])) * 1024 / (b - a)
            return math.nan
        name = dict(LANGS).get(l, l)
        print(f"| {sc} | {name} | " + " | ".join(cells) + f" | {fmt(slope(64, 1000))} | {fmt(slope(64, 10000))} |")


ORDER = ["live store data", "store: free slots and garbage in spans", "store: free pages kept", "GC metadata",
         "request arenas", "thread heaps", "coroutine stacks", "buffers and pools", "binary", "other"]
RU = {
    "live store data": "живые данные store",
    "store: free slots and garbage in spans": "store: мусор и свободные слоты в спанах",
    "store: free pages kept": "store: свободные страницы, которые держит сборщик",
    "GC metadata": "метаданные сборщика",
    "request arenas": "арены запросов",
    "thread heaps": "кучи потоков",
    "coroutine stacks": "стеки сопрограмм и потоков",
    "buffers and pools": "буферы и пулы",
    "binary": "бинарник",
    "other": "прочее",
}


def idle_live(d):
    """Живое store по сборке простоя (summary.txt: «idle …: … live by GC X MB»)."""
    try:
        t = open(os.path.join(d, "khrip", "summary.txt")).read()
    except OSError:
        return None
    m = re.search(r"idle \d+s: RSS \d+ KB, live by GC ([0-9.]+) MB", t)
    return float(m.group(1)) if m else None


def go_stats(d):
    try:
        t = open(os.path.join(d, "go", "summary.txt")).read()
    except OSError:
        return None
    r = {}
    for when in ("before", "after-gc"):
        m = re.search(rf"memstats {when} (.*)", t)
        if m:
            r[when] = {k: int(v) for k, v in (x.split("=") for x in m.group(1).split())}
    m = re.search(r"load snapshot: RSS (\d+) KB", t)
    r["rss_load"] = int(m.group(1)) if m else None
    m = re.search(r"after run: RSS (\d+) KB, HWM (\d+) KB", t)
    if m:
        r["rss_after"], r["hwm"] = int(m.group(1)), int(m.group(2))
    return r


def attr_table(root):
    first = ["inventory", "bank", "polls", "notes", "shortener", "ratelimit", "shop", "shop-1500", "ledger"]
    scen = sorted((d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d, "khrip"))),
                  key=lambda d: (first.index(d) if d in first else len(first), d))
    cols = []
    for sc in scen:
        p = os.path.join(root, sc, "khrip", "load.json")
        if not os.path.exists(p):
            continue
        j = json.load(open(p))
        cat = dict(j["categories"])
        live = idle_live(os.path.join(root, sc))
        alloc = cat.get("live store data", 0)
        pi = os.path.join(root, sc, "khrip", "idle.json")
        if os.path.exists(pi):
            # живое — по сборке простоя (те же данные: запросов больше не было),
            # в памяти; остальное в занятых спанах снимка под нагрузкой — мусор
            # до сборки и свободные слоты
            ji = json.load(open(pi))
            lv = min(ji["categories"].get("live store data", 0), alloc)
            cat["store: free slots and garbage in spans"] = cat.get("store: free slots and garbage in spans", 0) + alloc - lv
            cat["live store data"] = lv
        cols.append((sc, j, cat, live, go_stats(os.path.join(root, sc))))
    print("| Часть, МБ | " + " | ".join(c[0] for c in cols) + " |")
    print("|---|" + "---:|" * len(cols))
    print("| **RSS Khrip в снимке** | " + " | ".join(f"**{c[1]['vmrss'] / MB:.1f}**" for c in cols) + " |")
    for k in ORDER:
        print(f"| {RU[k]} | " + " | ".join(f"{c[2].get(k, 0) / MB:.1f}" for c in cols) + " |")
    print("| арен с памятью, шт. (медиана, макс., КБ) | " + " | ".join(
        f"{len(c[1]['arenas'])} ({sorted(c[1]['arenas'])[len(c[1]['arenas']) // 2] // 1024 if c[1]['arenas'] else 0}, {max(c[1]['arenas']) // 1024 if c[1]['arenas'] else 0})" for c in cols) + " |")
    print("| **Go: RSS в тот же момент** | " + " | ".join(
        f"**{c[4]['rss_load'] / 1024:.1f}**" if c[4] and c[4].get("rss_load") else "—" for c in cols) + " |")
    print("| Go: HeapAlloc до сборки / после | " + " | ".join(
        f"{c[4]['before']['heap_alloc'] / MB:.1f} / {c[4]['after-gc']['heap_alloc'] / MB:.1f}" if c[4] and "after-gc" in c[4] else "—" for c in cols) + " |")
    print("| Go: HeapInuse / свободно и не отдано / стеки | " + " | ".join(
        f"{c[4]['before']['heap_inuse'] / MB:.1f} / {(c[4]['before']['heap_idle'] - c[4]['before']['heap_released']) / MB:.1f} / {c[4]['before']['stack_inuse'] / MB:.1f}"
        if c[4] and "before" in c[4] else "—" for c in cols) + " |")
    print("| живое store Khrip по сборке (в памяти) | " + " | ".join(
        f"{c[3]:.1f} ({c[2]['live store data'] / MB:.1f})" if c[3] else "—" for c in cols) + " |")
    print("| живое store Khrip / HeapAlloc Go после сборки | " + " | ".join(
        f"{c[3] / (c[4]['after-gc']['heap_alloc'] / MB):.2f}" if c[3] and c[4] and "after-gc" in c[4] else "—" for c in cols) + " |")


def attr_tsv(root):
    print("scenario\tsnapshot\tpart\tmb")
    for sc in sorted(os.listdir(root)):
        for snap in ("load", "idle"):
            p = os.path.join(root, sc, "khrip", snap + ".json")
            if not os.path.exists(p):
                continue
            j = json.load(open(p))
            print(f"{sc}\tkhrip-{snap}\tvmrss\t{j['vmrss'] / MB:.2f}")
            for k in ORDER:
                print(f"{sc}\tkhrip-{snap}\t{k}\t{j['categories'].get(k, 0) / MB:.2f}")
            st = j.get("store") or {}
            for k in ("committed", "resident", "inuse_resident", "alloc_bytes", "alloc_resident", "free_slot_bytes", "tail_bytes", "free_resident"):
                if k in st:
                    print(f"{sc}\tkhrip-{snap}\tstore {k}\t{st[k] / MB:.2f}")
            if j.get("arenas"):
                print(f"{sc}\tkhrip-{snap}\tarenas with memory (count)\t{len(j['arenas'])}")
        live = idle_live(os.path.join(root, sc))
        if live is not None:
            print(f"{sc}\tkhrip-idle\tlive by GC log\t{live:.2f}")
        g = go_stats(os.path.join(root, sc))
        if g:
            if g.get("rss_load"):
                print(f"{sc}\tgo-load\tvmrss\t{g['rss_load'] / 1024:.2f}")
            for when in ("before", "after-gc"):
                for k, v in sorted(g.get(when, {}).items()):
                    if k.endswith(("_alloc", "_inuse", "_idle", "_released", "_sys")):
                        print(f"{sc}\tgo-{when}\t{k}\t{v / MB:.2f}")
                if when in g:
                    print(f"{sc}\tgo-{when}\theap_objects (count)\t{g[when]['heap_objects']}")


VARIANTS = [("khrip", "Khrip"), ("khrip-m1", "Khrip, m = 1"), ("khrip-m1-gc50", "Khrip, m = 1, KHRIP_GC=50"), ("go", "Go")]


def long_table(path):
    rs = rows(path)
    data = {(r["scenario"], r["variant"]): r for r in rs}
    scen = []
    for r in rs:
        if r["scenario"] not in scen:
            scen.append(r["scenario"])
    print("| Сценарий | Вариант | Пик, МБ | Среднее за последние 5 мин, МБ | Наклон за 5 мин, МБ/с | Живое в конце, МБ | Сборок (за замер) | мкс процессора на запрос | p99, мс | max, мс |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for sc in scen:
        go = data.get((sc, "go"))
        for v, name in VARIANTS:
            r = data.get((sc, v))
            if not r:
                continue
            peak = r["rss_peak_mb"]
            if go and v != "go":
                ratio = num(r["rss_peak_mb"]) / num(go["rss_peak_mb"])
                peak += f" ({ratio:.2f})" if ratio <= 1 else f" (**{ratio:.2f}**)"
            behind = " ⚠" if r["behind"] != "ok" else ""
            print(f"| {sc} | {name}{behind} | {peak} | {r['rss_mean_last300_mb']} | {num(r['rss_slope_last300_mb_s']):+.3f} | {r['live_end_mb']} | "
                  f"{r['gc_total']} ({r['gc_in_run']}) | {r['cpu_us_per_req']} | {r['p99_ms']} | {r['max_ms']} |")


def timeline(root, step_s=60):
    """RSS в конце каждой минуты от начала прогрева (из rss.tsv, мс CLOCK_MONOTONIC)."""
    out = []
    for sc in sorted(os.listdir(root)):
        for v, name in VARIANTS:
            p = os.path.join(root, sc, v, "rss.tsv")
            if not os.path.exists(p):
                continue
            pts = [(int(r[1]), int(r[2])) for r in (l.split("\t") for l in open(p)) if len(r) == 3]
            if not pts:
                continue
            t0 = pts[0][0]
            marks = []
            k = 1
            j = 0
            best = 0
            for t, kb in pts:
                while t - t0 >= k * step_s * 1000:
                    marks.append(best)
                    k += 1
                best = kb
            marks.append(pts[-1][1])
            out.append((sc, name, [m / 1024 for m in marks]))
    n = max(len(m) for _, _, m in out) if out else 0
    print("| Сценарий | Вариант | " + " | ".join(f"{i + 1}" for i in range(n)) + " |")
    print("|---|---|" + "---:|" * n)
    for sc, name, m in out:
        print(f"| {sc} | {name} | " + " | ".join(f"{x:.0f}" for x in m) + " |" + " — |" * (n - len(m)))


if __name__ == "__main__":
    kind, path = sys.argv[1], sys.argv[2]
    {"rate": rate_table, "conn": conn_table, "attr": attr_table, "attr-tsv": attr_tsv, "long": long_table,
     "timeline": timeline}[kind](path)
