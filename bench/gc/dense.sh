#!/usr/bin/env bash
# Плотные арены держателей (bench/gc/dense.kh): куски разметки и уборки, конец
# разметки, помощь писателя и память передачи арен (hbuf). Сервер на 4
# потоках, 300 000 товаров; держатели копируют каждую ссылку в свою арену и
# ждут 30 мс, затем 3 с; в конце — 12 держателей 10 с и простой 13 с: RSS
# после простоя. Писатель мусорит быстрее, чем идёт разметка.
#
#   bench/gc/dense.sh [корень khc]   (по умолчанию этот репозиторий)
#
# Порт GATE_PORT (по умолчанию 8080). Проверка: у половины сборок самый долгий
# кусок разметки занял не больше SLICE_CPU_MAX мкс процессора (по умолчанию
# 300; процессорное время потока — без вытеснения, но с прерываниями, ядро
# без IRQ_TIME_ACCOUNTING относит их к прерванному потоку), конец разметки —
# не больше 2 мс, ни одного неверного ответа, а с держателями по 3 с — ни
# одной сборки у жёсткого предела после первых двух (шаг 6b: доля разметки и
# помощь писателя). Печатает задержки писателя и пик RSS каждого прогона.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kroot=${1:-$root}
port=${GATE_PORT:-8080}
SLICE_CPU_MAX=${SLICE_CPU_MAX:-300}
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
KHRIP_GC_LOG=1 "$kroot/build/khc" -o "$tmp/dense" "$here/dense.kh" || exit 1

start() {
	PORT=$port THREADS=4 KHRIP_GC_LOG=1 "$tmp/dense" 2>"$1" &
	pid=$!
	for _ in $(seq 500); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/stats" && break
		sleep 0.01
	done
	curl -s -o /dev/null -X POST "http://127.0.0.1:$port/seed/300000"
}
stop() {
	kill "$pid"
	wait "$pid" 2>/dev/null
	pid=
}
rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status"; }

ok=1
: >"$tmp/all.log"
for ms in 30 3000; do
	start "$tmp/d$ms.log"
	python3 "$here/dense.py" "$port" 15 "$ms" 6 >"$tmp/d$ms.out" &
	drv=$!
	peak=0
	while kill -0 "$drv" 2>/dev/null; do
		r=$(rss)
		((r > peak)) && peak=$r
		sleep 0.1
	done
	stop
	cat "$tmp/d$ms.log" >>"$tmp/all.log"
	echo "holders sleeping $ms ms: $(tr '\n' ' ' <"$tmp/d$ms.out")peak RSS $((peak / 1024)) MB"
	python3 - "$tmp/d$ms.log" "$tmp/d$ms.out" "$ms" <<'PY' || ok=0
import re, sys
log, out, ms = open(sys.argv[1]).read(), open(sys.argv[2]).read(), int(sys.argv[3])
lines = [l for l in log.splitlines() if re.match(r"gc \d+ \(", l)]
rows = re.findall(r"arenas (\d+) \((\d+) KB, (\d+) handed off\).*?\(max (\d+) µs, cpu (\d+) µs\)", log)
term = [int(x) for x in re.findall(r"term (\d+) µs \(\d+ tries\)", log)]
sweep = re.findall(r"slices \(longest (\d+) µs, cpu (\d+) µs\)", log)
assists = sum(int(x) for x in re.findall(r"assists (\d+)", log))
# сборки у жёсткого предела: доделка разметки потока и сборка целиком в запросе
hard = [i for i, l in enumerate(lines) if "in request" in l]
whole = len(re.findall(r"pause [0-9.]+ ms", log))
cpu = sorted(int(r[4]) for r in rows)
wall = sorted(int(r[3]) for r in rows)
swc = sorted(int(c) for _, c in sweep)
sww = sorted(int(w) for w, _ in sweep)
bad = [k for k in re.findall(r"'([^']*)': \d+", out) if k != "ok 0"]
med = lambda xs: xs[len(xs) // 2] if xs else 0
if cpu:
    print(f"  {len(lines)} cycles ({len(rows)} incremental, {whole} whole; {len(hard)} at the hard limit), {sum(int(r[2]) for r in rows)} arenas handed off, {assists} writer assists; longest slice per cycle: cpu median {med(cpu)}, max {cpu[-1]} µs; wall median {med(wall)}, max {wall[-1]} µs; termination max {max(term or [0])} µs; longest sweep slice per cycle: cpu median {med(swc)}, max {max(swc or [0])} µs; wall median {med(sww)}, max {max(sww or [0])} µs")
errs = []
if term and max(term) > 2000:
    errs.append(f"termination {max(term)} µs")
if bad:
    errs.append(f"wrong answers {bad}")
# держатели по 3 с: в установившемся режиме (после первых двух сборок) ни одна
# сборка не кончается у жёсткого предела
if ms >= 3000 and [i for i in hard if i >= 2]:
    errs.append(f"{len([i for i in hard if i >= 2])} cycles at the hard limit after the first two")
if errs:
    print("  FAIL: " + "; ".join(errs)); sys.exit(1)
PY
done
python3 - "$tmp/all.log" "$SLICE_CPU_MAX" <<'PY' || ok=0
import re, sys
cpu = sorted(int(x) for x in re.findall(r"\(max \d+ µs, cpu (\d+) µs\)", open(sys.argv[1]).read()))
lim = int(sys.argv[2])
if not cpu:
    print("FAIL: no incremental cycles"); sys.exit(1)
med = cpu[len(cpu) // 2]
print(f"longest slice per cycle, both runs: cpu median {med} µs over {len(cpu)} cycles (limit {lim})")
if med > lim:
    print(f"FAIL: slice cpu median {med} > {lim} µs"); sys.exit(1)
PY

start "$tmp/rss.log"
r0=$(rss)
python3 "$here/dense.py" "$port" 10 30 12 >/dev/null
r1=$(rss)
sleep 13
r2=$(rss)
stop
echo "12 holders: RSS seeded $((r0 / 1024)) MB, after load $((r1 / 1024)) MB, after 13 s idle $((r2 / 1024)) MB; $(tail -1 "$tmp/rss.log" | grep -o 'live [0-9.]* MB')"
((ok)) && echo ok || { echo FAIL; exit 1; }
