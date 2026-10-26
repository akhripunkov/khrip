#!/usr/bin/env bash
# Проверка «да/нет» сборщика store (docs/design/v0.13-store-gc.md §14 шаг 5,
# §16): долгий прогон patch — одни и те же товары обновляются без остановки,
# store не растёт — с RSS каждую секунду и паузами из KHRIP_GC_LOG (сборки
# целиком — пауза; инкрементальные, шаг 6, — начало, самый долгий кусок
# разметки, конец разметки и уборка); затем удаление 90% store (подряд и
# вразнобой) с простоем.
#
#   bench/gc/gate.sh [секунд soak] [корень khc]   (по умолчанию 60 и этот репозиторий;
#                                                 khc — <корень>/build/khc)
#
# Сервер на ядрах SERVER_CPUS, wrk на CLIENT_CPUS, порт GATE_PORT (по умолчанию
# 8080, как eval/perf.sh).
# Пишет в OUT (по умолчанию bench/gc/out): soak.tsv (секунда, RSS КБ),
# soak.log (строки сборщика), delete.txt.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
secs=${1:-60}
kroot=${2:-$root}
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
OUT=${OUT:-$here/out}
port=${GATE_PORT:-8080}
export SEED_PORT=$port
mkdir -p "$OUT"
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status"; }
hwm() { awk '/^VmHWM:/ { print $2 }' "/proc/$pid/status"; }
up() {
	for _ in $(seq 500); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/$1" && return 0
		sleep 0.01
	done
	return 1
}

# --- patch: soak ---
KHRIP_GC_LOG=1 "$kroot/build/khc" -o "$tmp/catalog" "$root/eval/solutions/catalog/khrip/main.kh" || exit 1
KHRIP_GC_LOG=1 PORT=$port taskset -c "$SERVER_CPUS" "$tmp/catalog" 2>"$OUT/soak.log" &
pid=$!
up products/1
python3 "$root/eval/load/seed.py" seed patch
echo "seeded: $(rss) KB"
LOAD_DIR=$root/eval/load taskset -c "$CLIENT_CPUS" wrk -t2 -c64 -d"${secs}s" --latency -s "$root/eval/load/patch.lua" http://127.0.0.1:$port >"$OUT/soak.wrk" 2>&1 &
wrk_pid=$!
: >"$OUT/soak.tsv"
for t in $(seq 1 "$secs"); do
	sleep 1
	printf '%s\t%s\n' "$t" "$(rss)" >>"$OUT/soak.tsv"
done
wait "$wrk_pid"
echo "patch soak ${secs}s: $(grep Requests/sec "$OUT/soak.wrk"), p99 $(awk '$1 == "99%" { print $2 }' "$OUT/soak.wrk"), peak $(hwm) KB, end $(rss) KB"
python3 "$root/eval/load/seed.py" verify patch
kill "$pid"
wait "$pid" 2>/dev/null
pid=
python3 - "$OUT/soak.tsv" "$OUT/soak.log" <<'PY'
import re, sys
rows = [tuple(map(int, l.split())) for l in open(sys.argv[1])]
xs = [r for r in rows if r[0] > 10]
if len(xs) > 2:
    n = len(xs); mx = sum(r[0] for r in xs) / n; my = sum(r[1] for r in xs) / n
    slope = sum((r[0] - mx) * (r[1] - my) for r in xs) / sum((r[0] - mx) ** 2 for r in xs)
    print(f"RSS after 10 s: min {min(r[1] for r in xs)} KB, max {max(r[1] for r in xs)} KB, slope {slope / 1024:.4f} MB/s")
log = open(sys.argv[2]).read()
heap = re.findall(r"heap ([0-9.]+)->([0-9.]+) MB, live ([0-9.]+) MB \((\d+) obj", log)
def stats(name, xs, unit):
    xs = sorted(xs)
    return f"{name} median {xs[len(xs) // 2]:.3f}, p99 {xs[int(len(xs) * 0.99)]:.3f}, max {xs[-1]:.3f} {unit}" if xs else f"{name} -"
# сборки целиком (в запросе, в простое): пауза; инкрементальные (поток
# сборщика): начало, самый долгий кусок разметки, конец разметки, уборка
p = [float(x) for x in re.findall(r"pause ([0-9.]+) ms", log)]
inc = re.findall(r"start (\d+) µs, mark ([0-9.]+) ms in (\d+) slices \(max (\d+) µs, cpu (\d+) µs\) over ([0-9.]+) ms, term (\d+) µs.*?, sweep ([0-9.]+) ms", log)
if heap:
    print(f"cycles {len(heap)} ({len(inc)} incremental, {len(p)} whole); heap before {heap[-1][0]} MB, live {heap[-1][2]} MB ({heap[-1][3]} objects)")
if p:
    print(stats("whole-cycle pause", p, "ms"))
if inc:
    print(stats("start", [int(r[0]) / 1000 for r in inc], "ms") + "; " + stats("max slice", [int(r[3]) / 1000 for r in inc], "ms") + "; " + stats("max slice cpu", [int(r[4]) / 1000 for r in inc], "ms"))
    print(stats("termination", [int(r[6]) / 1000 for r in inc], "ms") + "; " + stats("sweep", [float(r[7]) for r in inc], "ms") + f"; slices per cycle median {sorted(int(r[2]) for r in inc)[len(inc) // 2]}")
# уборка кусками (шаг 6b): самый долгий кусок сборки по часам и процессору;
# помощи писателей
sw = re.findall(r"slices \(longest (\d+) µs, cpu (\d+) µs\)", log)
if sw:
    print(stats("longest sweep slice", [int(a) / 1000 for a, _ in sw], "ms") + "; " + stats("cpu", [int(b) / 1000 for _, b in sw], "ms") + f"; writer assists {sum(int(x) for x in re.findall(r'assists (\d+)', log))}")
PY

# --- удаление 90%: подряд и вразнобой (DELETE=0 — без него, например для
# khc без сборщика) ---
[[ ${DELETE:-1} == 1 ]] || exit 0
KHRIP_GC_LOG=1 "$kroot/build/khc" -o "$tmp/delete" "$here/delete.kh" || exit 1
: >"$OUT/delete.txt"
for how in oldest random; do
	KHRIP_GC_LOG=1 PORT=$port taskset -c "$SERVER_CPUS" "$tmp/delete" 2>"$OUT/delete-$how.log" &
	pid=$!
	up stats
	for _ in $(seq 20); do
		curl -s -o /dev/null -X POST "http://127.0.0.1:$port/fill/10000"
	done
	full=$(rss)
	curl -s -o /dev/null -X POST "http://127.0.0.1:$port/delete/$how/200000"
	after=$(rss)
	sleep 15
	idle=$(rss)
	read -r left live heap cycles < <(curl -s "http://127.0.0.1:$port/stats")
	kill "$pid"
	wait "$pid" 2>/dev/null
	pid=
	limit=$((live * 3 / 2 / 1024 + 6144))
	verdict=ok
	((idle > limit)) && verdict=over
	echo "delete $how: 200000 -> $left products; RSS full $full KB, after delete $after KB, after 15 s idle $idle KB; live $((live / 1024)) KB, heap $((heap / 1024)) KB, $cycles cycles; gate 1.5 x live + 6 MB = $limit KB: $verdict" | tee -a "$OUT/delete.txt"
done
