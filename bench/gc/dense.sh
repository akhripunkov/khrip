#!/usr/bin/env bash
# Плотные арены держателей (bench/gc/dense.kh): куски разметки, конец разметки
# и память передачи арен (hbuf). Сервер на 4 потоках, 300 000 товаров;
# держатели копируют каждую ссылку в свою арену и ждут 30 мс, затем 3 с; в
# конце — 12 держателей 10 с и простой 13 с: RSS после простоя.
#
#   bench/gc/dense.sh [корень khc]   (по умолчанию этот репозиторий)
#
# Порт GATE_PORT (по умолчанию 8080). Проверка: у половины сборок самый долгий
# кусок разметки занял не больше SLICE_CPU_MAX мкс процессора (по умолчанию
# 300; процессорное время потока — без вытеснения, но с прерываниями, ядро
# без IRQ_TIME_ACCOUNTING относит их к прерванному потоку), конец разметки —
# не больше 2 мс, ни одного неверного ответа.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kroot=${1:-$root}
port=${GATE_PORT:-8080}
SLICE_CPU_MAX=${SLICE_CPU_MAX:-300}
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
"$kroot/build/khc" -o "$tmp/dense" "$here/dense.kh" || exit 1

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
	python3 "$here/dense.py" "$port" 15 "$ms" 6 >"$tmp/d$ms.out"
	stop
	cat "$tmp/d$ms.log" >>"$tmp/all.log"
	echo "holders sleeping $ms ms: $(tr '\n' ' ' <"$tmp/d$ms.out")"
	python3 - "$tmp/d$ms.log" "$tmp/d$ms.out" <<'PY' || ok=0
import re, sys
log, out = open(sys.argv[1]).read(), open(sys.argv[2]).read()
rows = re.findall(r"arenas (\d+) \((\d+) KB, (\d+) handed off\).*?\(max (\d+) µs, cpu (\d+) µs\)", log)
term = [int(x) for x in re.findall(r"term (\d+) µs \(\d+ tries\)", log)]
whole = len(re.findall(r"pause [0-9.]+ ms", log))
cpu = sorted(int(r[4]) for r in rows)
wall = sorted(int(r[3]) for r in rows)
bad = [k for k in re.findall(r"'([^']*)': \d+", out) if k != "ok 0"]
if cpu:
    print(f"  {len(rows)} incremental cycles ({whole} whole, at the hard limit), {sum(int(r[2]) for r in rows)} arenas handed off; longest slice per cycle: cpu median {cpu[len(cpu) // 2]}, max {cpu[-1]} µs; wall median {wall[len(wall) // 2]}, max {wall[-1]} µs; termination max {max(term or [0])} µs")
errs = []
if term and max(term) > 2000:
    errs.append(f"termination {max(term)} µs")
if bad:
    errs.append(f"wrong answers {bad}")
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
