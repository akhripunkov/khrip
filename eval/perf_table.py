"""Таблицы из results/perf.tsv: python3 eval/perf_table.py > eval/results/perf.md
Задачи с базой: python3 eval/perf_table.py eval/results/perf_db.tsv > eval/results/perf_db.md"""
import csv
import math
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
rows = list(csv.DictReader(open(sys.argv[1] if len(sys.argv) > 1 else f"{here}/results/perf.tsv"), delimiter="\t"))
langs = [("khrip", "Khrip"), ("go", "Go"), ("csharp", "C#"), ("python", "Python")]
scenarios = []
for r in rows:
    if r["scenario"] not in scenarios:
        scenarios.append(r["scenario"])
data = {(r["scenario"], r["lang"]): r for r in rows}

TITLES = {
    "shortener": "сокращатель: 90% переходов, 10% новых ссылок",
    "bank": "банк: 80% переводов, 20% чтений",
    "notes": "заметки: 90% чтений с токеном, 10% записей",
    "login": "вход: проверка пароля PBKDF2",
    "ratelimit": "лимит: 200 тыс. ключей",
    "catalog": "каталог: поиск по 2000 товаров",
    "patch": "каталог: только обновления товаров",
    "inventory": "склад: 70% заказов, 30% списка",
    "polls": "опросы: 60% голосов, 40% чтений",
    "bookings": "бронирование: 70% расписаний, 30% броней",
    "ledger": "ledger: 70% переводов, 20% счетов, 10% истории",
    "shop": "shop: 40% поиска, 30% карточек, 25% заказов, 5% сводки",
    "tracker": "tracker: 40% чтений, 20% правок, 20% новых задач, 20% сводки",
}


def num(v):
    return float(v) if v not in ("", None) else math.nan


db = bool(rows) and "db_cpu_us_per_req" in rows[0]
if db:
    for r in rows:
        r["total_cpu_us"] = str(num(r["cpu_us_per_req"]) + num(r["db_cpu_us_per_req"]))


def table(title, field, fmt, better):
    print(f"\n### {title}\n")
    print("| Сценарий | " + " | ".join(n for _, n in langs) + " |")
    print("|---|" + "---:|" * len(langs))
    for sc in scenarios:
        vals = [num(data[(sc, l)][field]) if (sc, l) in data else math.nan for l, _ in langs]
        ok = [v for v in vals if not math.isnan(v)]
        best = (max if better == "max" else min)(ok) if ok else None
        cells = []
        for v in vals:
            if math.isnan(v):
                cells.append("—")
            else:
                s = fmt(v)
                cells.append(f"**{s}**" if v == best else s)
        print(f"| {TITLES.get(sc, sc)} | " + " | ".join(cells) + " |")


def geo(field, lang):
    vals = [num(data[(sc, lang)][field]) for sc in scenarios if (sc, lang) in data]
    vals = [v for v in vals if v > 0]
    return math.exp(sum(map(math.log, vals)) / len(vals)) if vals else math.nan


thousands = lambda v: f"{v:,.0f}".replace(",", " ")
table("Пропускная способность, запросов в секунду (больше — лучше)", "rps", thousands, "max")
table("Задержка p99, мс (меньше — лучше)", "p99_ms", lambda v: f"{v:.2f}", "min")
table("Процессорное время на запрос, мкс (меньше — лучше)", "cpu_us_per_req", lambda v: f"{v:.1f}", "min")
if db:
    table("Процессор PostgreSQL на запрос, мкс (меньше — лучше)", "db_cpu_us_per_req", lambda v: f"{v:.0f}", "min")
    table("Процессор сервера и PostgreSQL вместе на запрос, мкс (меньше — лучше)", "total_cpu_us", lambda v: f"{v:.0f}", "min")
table("Память с данными до нагрузки (RSS), МБ (меньше — лучше)", "seeded_mb", lambda v: f"{v:.1f}", "min")
table("Память после нагрузки (RSS), МБ (меньше — лучше)", "after_mb", lambda v: f"{v:.1f}", "min")

# прирост памяти на запрос: нагрузка шла WARMUP + DURATION секунд (по умолчанию 3 + 10)
SECONDS = float(os.environ.get("LOAD_SECONDS", "13"))
for r in rows:
    grown = (num(r["after_mb"]) - num(r["seeded_mb"])) * 1024 * 1024
    r["bytes_per_req"] = str(max(grown, 0) / (num(r["rps"]) * SECONDS)) if num(r["rps"]) > 0 else ""
table("Прирост памяти на запрос, байт (меньше — лучше; данные сценария растут)", "bytes_per_req",
      lambda v: f"{v:.0f}", "min")

print("\n### Сводка: среднее геометрическое по сценариям\n")
print("| | " + " | ".join(n for _, n in langs) + " |")
print("|---|" + "---:|" * len(langs))
for title, field, fmt in [
    ("запросов в секунду", "rps", thousands),
    ("p50, мс", "p50_ms", lambda v: f"{v:.2f}"),
    ("p99, мс", "p99_ms", lambda v: f"{v:.2f}"),
    ("мкс процессора на запрос", "cpu_us_per_req", lambda v: f"{v:.1f}"),
] + ([
    ("мкс процессора PostgreSQL на запрос", "db_cpu_us_per_req", lambda v: f"{v:.0f}"),
    ("мкс процессора сервера и PostgreSQL", "total_cpu_us", lambda v: f"{v:.0f}"),
] if db else []) + [
    ("память в покое, МБ", "idle_mb", lambda v: f"{v:.1f}"),
    ("память с данными, МБ", "seeded_mb", lambda v: f"{v:.1f}"),
    ("память после нагрузки, МБ", "after_mb", lambda v: f"{v:.1f}"),
    ("запуск, мс", "startup_ms", lambda v: f"{v:.0f}"),
    ("сборка, с", "build_s", lambda v: f"{v:.1f}"),
]:
    cells = []
    for l, _ in langs:
        v = geo(field, l)
        if field == "build_s" and l == "python":
            cells.append("—")
        elif math.isnan(v):
            cells.append("< 0.1")
        else:
            cells.append(fmt(v))
    print(f"| {title} | " + " | ".join(cells) + " |")
sizes = []
for l, _ in langs:
    v = [num(data[(sc, l)]["size_bytes"]) for sc in scenarios if (sc, l) in data]
    sizes.append(f"{sum(v) / len(v) / 1024:.0f} КБ" if v else "—")
print("| размер приложения | " + " | ".join(sizes) + " |")
print("\nРазмер: у Khrip и Go — весь статический бинарник; у C# — сборка без среды .NET"
      " (её ставят отдельно, ~70 МБ); у Python — main.py без интерпретатора и пакетов.")

bad = [r for r in rows if r["invariant"] != "ok"]
print("\nИнварианты под нагрузкой (деньги в банке, товар на складе): " +
      ("все сохранились." if not bad else "нарушены: " + ", ".join(f"{r['scenario']}/{r['lang']}" for r in bad)))
errs = [f"{TITLES.get(r['scenario'], r['scenario']).split(':')[0]} / {dict(langs)[r['lang']]}: {r['errors_pct']}%"
        for r in rows if num(r["errors_pct"]) > 0]
if errs:
    print("\nОтветы 4xx/5xx и ошибки сокетов (ожидаемые 409/429 сценария тоже здесь): " + "; ".join(errs) + ".")
