"""Сводка кругов: медиана и разброс по варианту.

    python3 stats.py closed.tsv            — строки eval/perf.sh (scenario, lang, ...)
    python3 stats.py ab3_catalog.tsv       — строки ab.sh (round, scenario, variant, ...)
"""
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
key = "variant" if "variant" in rows[0] else "lang"
cpu = "cpu_us_per_req"
groups = {}
for r in rows:
    groups.setdefault((r["scenario"], r[key]), []).append(r)


def med(rs, f):
    v = [float(r[f]) for r in rs]
    return statistics.median(v), min(v), max(v)


print("сценарий\tвариант\tкругов\trps (медиана; мин–макс)\tпроцессор мкс/запрос\tp50 мс\tp99 мс")
for (sc, v), rs in groups.items():
    a = med(rs, "rps")
    c = med(rs, cpu)
    p50 = med(rs, "p50_ms")
    p99 = med(rs, "p99_ms")
    print(f"{sc}\t{v}\t{len(rs)}\t{a[0]:.0f} ({a[1]:.0f}–{a[2]:.0f})\t{c[0]:.1f} ({c[1]:.1f}–{c[2]:.1f})\t{p50[0]:.2f}\t{p99[0]:.2f} ({p99[1]:.2f}–{p99[2]:.2f})")
