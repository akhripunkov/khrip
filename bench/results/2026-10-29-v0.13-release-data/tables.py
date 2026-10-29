#!/usr/bin/env python3
"""Таблицы и пороги итогового замера 0.13.0 (метод v2) из сырых строк этой папки.

    python3 tables.py [папка]  > tables.md

Папка (по умолчанию — эта) — строки eval/perf.sh и bench/mem/long.sh:
closed_r1.tsv, closed_r2.tsv (замкнутый цикл без базы, два круга),
closed_db_r1.tsv, closed_db_r2.tsv (с базой), rate.tsv (одинаковая частота),
conn.tsv (память от числа соединений), long.tsv (10 минут), checks.tsv
(eval/run.sh по задачам и языкам).

Пороги (бриф выпуска): Khrip ≥ лучшего из основных языков (Go, C#, Java,
Node, Bun; у задач с базой ещё node-cluster) в том же прогоне — по запросам в
секунду и процессору на запрос в замкнутом цикле, по p99 и пиковому RSS при
одинаковой частоте. Замкнутый цикл — среднее двух кругов (оно же медиана
двух); при одинаковой частоте в сравнение входят только прогоны, которые
частоту удержали (ok): у отставшего (behind) меньше запросов и данных, его
память и задержки — не при той же нагрузке. Python — только для сведения.
"""
import csv
import math
import os
import sys

here = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
NAMES = {"khrip": "Khrip", "go": "Go", "csharp": "C#", "java": "Java", "node": "Node", "bun": "Bun",
         "node-cluster": "Node ×2", "python": "Python"}
LANGS = ["khrip", "go", "csharp", "java", "node", "bun", "node-cluster", "python"]
MAIN = ["go", "csharp", "java", "node", "bun", "node-cluster"]
SCEN = ["shortener", "bank", "notes", "login", "ratelimit", "catalog", "patch", "inventory", "polls", "bookings",
        "ledger", "shop", "tracker"]
DB = {"ledger", "shop", "tracker"}


def read(name):
    p = os.path.join(here, name)
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return list(csv.DictReader(f, delimiter="\t"))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return math.nan


def fmt(v, digits=0):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "—"
    s = f"{v:,.{digits}f}".replace(",", " ").replace(".", ",")
    return s


def ratio(a, b):
    return a / b if b and not math.isnan(a) and not math.isnan(b) else math.nan


# ---------- замкнутый цикл ----------
closed = {}  # (sc, lang) -> [row r1, row r2]
for r in ("1", "2"):
    for row in read(f"closed_r{r}.tsv") + read(f"closed_db_r{r}.tsv"):
        closed.setdefault((row["scenario"], row["lang"]), {})[r] = row


def cval(sc, lang, field):
    rows = closed.get((sc, lang), {})
    vals = [num(rows[r].get(field)) for r in sorted(rows) if not math.isnan(num(rows[r].get(field)))]
    return sum(vals) / len(vals) if vals else math.nan


def crounds(sc, lang, field):
    rows = closed.get((sc, lang), {})
    return [num(rows[r].get(field)) for r in ("1", "2") if r in rows]



rate = {(r["scenario"], r["lang"]): r for r in read("rate.tsv")}
conn = {(r["scenario"], r["lang"], r["connections"]): r for r in read("conn.tsv")}
long_ = {(r["scenario"], r["variant"]): r for r in read("long.tsv")}


def table(title, header, rows, note=None):
    print(f"\n{title}\n")
    print("| " + " | ".join(header) + " |")
    print("|---|" + "---:|" * (len(header) - 1))
    for r in rows:
        print("| " + " | ".join(r) + " |")
    if note:
        print(f"\n{note}")


def best_mark(vals, better):
    ok = [v for v in vals if not math.isnan(v)]
    if not ok:
        return None
    return max(ok) if better == "max" else min(ok)


def closed_table(field, title, digits, better, rounds=False, scen=SCEN):
    langs = [l for l in LANGS if any((sc, l) in closed for sc in scen)]
    rows = []
    for sc in scen:
        vals = [cval(sc, l, field) for l in langs]
        b = best_mark([v for v, l in zip(vals, langs) if l != "python"], better)
        cells = []
        for v, l in zip(vals, langs):
            s = fmt(v, digits)
            if rounds and not math.isnan(v):
                rr = crounds(sc, l, field)
                if len(rr) == 2:
                    s += f" ({fmt(rr[0], digits)} / {fmt(rr[1], digits)})"
            cells.append(f"**{s}**" if v == b else s)
        rows.append([sc] + cells)
    table(title, ["Сценарий"] + [NAMES[l] for l in langs], rows)


# ---------- пороги ----------
def gate_rows():
    out = []
    for sc in SCEN:
        g = {"sc": sc}
        # замкнутый цикл: запросы и процессор
        for key, field, better in (("rps", "rps", "max"), ("cpu", "cpu_us_per_req", "min")):
            k = cval(sc, "khrip", field)
            cand = [(cval(sc, l, field), l) for l in MAIN if (sc, l) in closed]
            cand = [c for c in cand if not math.isnan(c[0])]
            if not cand or math.isnan(k):
                g[key] = None
                continue
            bv, bl = (max if better == "max" else min)(cand)
            ok = k >= bv if better == "max" else k <= bv
            # по кругам: тот же язык-соперник в каждом круге
            kr = crounds(sc, "khrip", field)
            wins = 0
            for i in range(len(kr)):
                rr = [crounds(sc, l, field) for l in MAIN if (sc, l) in closed]
                rv = [x[i] for x in rr if len(x) > i]
                if not rv:
                    continue
                bb = max(rv) if better == "max" else min(rv)
                wins += kr[i] >= bb if better == "max" else kr[i] <= bb
            g[key] = (ok, k, bv, bl, wins, len(kr))
        # одинаковая частота: p99 и пиковый RSS среди удержавших частоту
        kr = rate.get((sc, "khrip"))
        for key, field in (("p99", "p99_ms"), ("rss", "rss_peak_mb")):
            if not kr:
                g[key] = None
                continue
            k = num(kr[field])
            cand = [(num(rate[(sc, l)][field]), l) for l in MAIN if (sc, l) in rate and rate[(sc, l)]["behind"] == "ok"]
            behind = [l for l in MAIN if (sc, l) in rate and rate[(sc, l)]["behind"] != "ok"]
            if not cand:
                g[key] = (True, k, math.nan, "—", behind, kr["behind"])
                continue
            bv, bl = min(cand)
            g[key] = (k <= bv and kr["behind"] == "ok", k, bv, bl, behind, kr["behind"])
        out.append(g)
    return out


def cell_closed(c, digits):
    if c is None:
        return "—"
    ok, k, bv, bl, wins, n = c
    mark = "✅" if ok else "❌"
    return f"{mark} {fmt(k, digits)} / {fmt(bv, digits)} {NAMES[bl]} ({fmt(ratio(k, bv), 2)}; кругов {wins} из {n})"


def cell_rate(c, digits):
    if c is None:
        return "—"
    ok, k, bv, bl, behind, kb = c
    mark = "✅" if ok else "❌"
    s = f"{mark} {fmt(k, digits)} / {fmt(bv, digits)} {NAMES.get(bl, bl)} ({fmt(ratio(k, bv), 2)})"
    if kb != "ok":
        s += " Khrip behind"
    return s


if __name__ == "__main__":
    print("<!-- построено tables.py из сырых строк этой папки -->")
    gates = gate_rows()
    table("### Пороги по сценариям (Khrip / лучший из основных языков, отношение)",
          ["Сценарий", "запросов/с, замкнутый цикл", "мкс процессора на запрос", "p99 при одной частоте, мс",
           "пиковый RSS при одной частоте, МБ"],
          [[g["sc"], cell_closed(g["rps"], 0), cell_closed(g["cpu"], 1), cell_rate(g["p99"], 2), cell_rate(g["rss"], 1)]
           for g in gates])
    passed = {k: sum(1 for g in gates if g[k] and g[k][0]) for k in ("rps", "cpu", "p99", "rss")}
    print(f"\nВзято: запросы {passed['rps']}/13, процессор {passed['cpu']}/13, p99 {passed['p99']}/13, "
          f"пиковый RSS {passed['rss']}/13.")

    closed_table("rps", "### Замкнутый цикл: запросов в секунду (среднее двух кругов; круги в скобках)", 0, "max", rounds=True)
    closed_table("cpu_us_per_req", "### Замкнутый цикл: мкс процессора сервера на запрос", 1, "min")
    closed_table("p50_ms", "### Замкнутый цикл: p50, мс", 2, "min")
    closed_table("p99_ms", "### Замкнутый цикл: p99, мс", 2, "min")
    closed_table("peak_mb", "### Замкнутый цикл: пиковый RSS (VmHWM), МБ", 1, "min")
    closed_table("startup_ms", "### Запуск, мс (медиана трёх, среднее двух кругов)", 0, "min")
    closed_table("db_cpu_us_per_req", "### Замкнутый цикл, задачи с базой: мкс процессора PostgreSQL на запрос", 0, "min",
                 scen=[s for s in SCEN if s in DB])
    # размер — от сценария не зависит, кроме языка
    sizes = {}
    for (sc, l), rows in closed.items():
        for r in rows.values():
            sizes.setdefault(l, {})[sc] = num(r["size_bytes"])
    rows = []
    for l in [l for l in LANGS if l in sizes]:
        v = sorted(sizes[l].values())
        rows.append([NAMES[l], f"{fmt(v[0] / 1e6, 2)}–{fmt(v[-1] / 1e6, 2)}"])
    table("### Размер развёртываемого решения, МБ", ["Язык", "МБ"], rows,
          "Khrip, Go — бинарник; C# — папка публикации без .pdb (+ среда .NET); Java — jar Spring Boot (+ JRE); "
          "Node, Bun — server.js с node_modules (+ Node или Bun); Python — main.py (+ Python и пакеты).")

    # ---------- одинаковая частота ----------
    rl = [l for l in LANGS if any((sc, l) in rate for sc in SCEN)]
    for field, title, digits in (("achieved_rps", "Достигнутая частота, запросов/с (⚠ — behind)", 0),
                                 ("p50_ms", "p50, мс", 2), ("p99_ms", "p99, мс", 2), ("p999_ms", "p99,9, мс", 2),
                                 ("cpu_us_per_req", "мкс процессора сервера на запрос", 1),
                                 ("rss_peak_mb", "пиковый RSS, МБ", 1), ("rss_mean_mb", "средний RSS за замер, МБ", 1)):
        rows = []
        for sc in SCEN:
            if not any((sc, l) in rate for l in rl):
                continue
            vals = []
            for l in rl:
                r = rate.get((sc, l))
                vals.append((num(r[field]) if r else math.nan, r))
            okv = [v for (v, r), l in zip(vals, rl) if r and r["behind"] == "ok" and l != "python"]
            b = None
            if field != "achieved_rps" and okv:
                b = max(okv) if field in () else min(okv)
            cells = []
            for (v, r), l in zip(vals, rl):
                s = fmt(v, digits)
                if r and r["behind"] != "ok":
                    s += " ⚠"
                cells.append(f"**{s}**" if b is not None and v == b and r["behind"] == "ok" else s)
            rate_v = next((r["rate"] for v, r in vals if r), "")
            rows.append([f"{sc} ({rate_v}/с)"] + cells)
        table(f"### Одинаковая частота: {title}", ["Сценарий"] + [NAMES[l] for l in rl], rows)

    # ---------- соединения ----------
    cl = [l for l in LANGS if any(k[1] == l for k in conn)]
    rows = []
    for sc in ("shortener", "bank", "ledger"):
        for l in cl:
            r = {n: conn.get((sc, l, n)) for n in ("64", "1000", "10000")}
            if not any(r.values()):
                continue
            m = {n: num(r[n]["rss_mean_mb"]) if r[n] else math.nan for n in r}
            s1 = (m["1000"] - m["64"]) * 1024 / (1000 - 64)
            s2 = (m["10000"] - m["64"]) * 1024 / (10000 - 64)
            flags = []
            for n in r:
                if r[n] and (r[n]["behind"] != "ok" or num(r[n]["errors_pct"]) > 0):
                    flags.append(f"{n}: {r[n]['behind']}, ошибок {r[n]['errors_pct']} %, fds {r[n]['server_fds']}")
            rows.append([sc, NAMES[l], fmt(m["64"], 1), fmt(m["1000"], 1), fmt(m["10000"], 1), fmt(s1, 1), fmt(s2, 1),
                         "; ".join(flags) or "ok"])
    table("### Память от числа соединений (500 запросов/с; RSS — среднее за последние 30 с)",
          ["Сценарий", "Язык", "64, МБ", "1000, МБ", "10000, МБ", "наклон 64→1000, КБ/соед.", "наклон 64→10000, КБ/соед.",
           "замечания"], rows)

    # ---------- 10 минут ----------
    rows = []
    for sc in ("bank", "notes"):
        for l in ["khrip", "go", "csharp", "java", "node", "bun"]:
            r = long_.get((sc, l))
            if not r:
                continue
            rows.append([sc, NAMES[l], r["achieved_rps"] + ("" if r["behind"] == "ok" else " ⚠"), r["p99_ms"], r["p999_ms"],
                         r["rss_peak_mb"], r["rss_mean_last300_mb"], r["rss_slope_last300_mb_s"], r["cpu_us_per_req"]])
    table("### 10 минут при одинаковой частоте", ["Сценарий", "Язык", "достигнуто", "p99, мс", "p99,9, мс", "пик RSS, МБ",
                                                 "среднее за последние 300 с, МБ", "наклон, МБ/с", "мкс на запрос"], rows)
