"""Сводка открытого цикла: медианы по кругам.

    python3 ratestats.py rate.tsv            — строки eval/perf_rate.sh (scenario, lang, rate, ...)
    python3 ratestats.py abrate_catalog.tsv  — строки ab.sh с RATE (round, scenario, variant, rate, ...)
"""
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
key = "variant" if "variant" in rows[0] else "lang"
ach = "achieved_rps" if "achieved_rps" in rows[0] else "rps"
groups = {}
for r in rows:
    groups.setdefault((r["scenario"], r["rate"], r[key]), []).append(r)


def med(rs, f):
    v = [float(r[f]) for r in rs if r.get(f) not in (None, "", "-")]
    if not v:
        return "-"
    m = statistics.median(v)
    return f"{m:.2f} ({min(v):.2f}–{max(v):.2f})" if len(v) > 1 else f"{m:.2f}"


print("сценарий\tчастота\tвариант\tкругов\tдостигнуто\tp50\tp99\tp99,9\tmax\tпроцессор мкс/запрос\tbehind")
for (sc, rate, v), rs in sorted(groups.items()):
    behind = sum(1 for r in rs if r.get("behind", "ok") == "behind")
    print(f"{sc}\t{rate}\t{v}\t{len(rs)}\t{med(rs, ach)}\t{med(rs, 'p50_ms')}\t{med(rs, 'p99_ms')}\t{med(rs, 'p999_ms')}\t{med(rs, 'max_ms')}\t{med(rs, 'cpu_us_per_req')}\t{behind}")
