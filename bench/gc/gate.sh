#!/usr/bin/env bash
# Проверка «да/нет» сборщика store (docs/design/v0.13-store-gc.md §14 шаг 5,
# §16): долгий прогон patch — одни и те же товары обновляются без остановки,
# store не растёт — с RSS каждую секунду и паузами из KHRIP_GC_LOG; затем
# удаление 90% store (подряд и вразнобой) с простоем.
#
#   bench/gc/gate.sh [секунд soak] [корень khc]   (по умолчанию 60 и этот репозиторий;
#                                                 khc — <корень>/build/khc)
#
# Сервер на ядрах SERVER_CPUS, wrk на CLIENT_CPUS, порт 8080 (как eval/perf.sh).
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
mkdir -p "$OUT"
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status"; }
hwm() { awk '/^VmHWM:/ { print $2 }' "/proc/$pid/status"; }
up() {
	for _ in $(seq 500); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:8080/$1" && return 0
		sleep 0.01
	done
	return 1
}

# --- patch: soak ---
"$kroot/build/khc" -o "$tmp/catalog" "$root/eval/solutions/catalog/khrip/main.kh" || exit 1
KHRIP_GC_LOG=1 PORT=8080 taskset -c "$SERVER_CPUS" "$tmp/catalog" 2>"$OUT/soak.log" &
pid=$!
up products/1
python3 "$root/eval/load/seed.py" seed patch
echo "seeded: $(rss) KB"
LOAD_DIR=$root/eval/load taskset -c "$CLIENT_CPUS" wrk -t2 -c64 -d"${secs}s" --latency -s "$root/eval/load/patch.lua" http://127.0.0.1:8080 >"$OUT/soak.wrk" 2>&1 &
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
p = [float(m.group(1)) for m in re.finditer(r"pause ([0-9.]+) ms", open(sys.argv[2]).read())]
heap = re.findall(r"heap ([0-9.]+)->([0-9.]+) MB, live ([0-9.]+) MB \((\d+) obj\)", open(sys.argv[2]).read())
if p:
    p.sort()
    print(f"cycles {len(p)}, pause median {p[len(p) // 2]:.2f} ms, p99 {p[int(len(p) * 0.99)]:.2f} ms, max {p[-1]:.2f} ms; heap before {heap[-1][0]} MB, live {heap[-1][2]} MB ({heap[-1][3]} objects)")
PY

# --- удаление 90%: подряд и вразнобой (DELETE=0 — без него, например для
# khc без сборщика) ---
[[ ${DELETE:-1} == 1 ]] || exit 0
"$kroot/build/khc" -o "$tmp/delete" "$here/delete.kh" || exit 1
: >"$OUT/delete.txt"
for how in oldest random; do
	KHRIP_GC_LOG=1 PORT=8080 taskset -c "$SERVER_CPUS" "$tmp/delete" 2>"$OUT/delete-$how.log" &
	pid=$!
	up stats
	for _ in $(seq 20); do
		curl -s -o /dev/null -X POST "http://127.0.0.1:8080/fill/10000"
	done
	full=$(rss)
	curl -s -o /dev/null -X POST "http://127.0.0.1:8080/delete/$how/200000"
	after=$(rss)
	sleep 15
	idle=$(rss)
	read -r left live heap cycles < <(curl -s "http://127.0.0.1:8080/stats")
	kill "$pid"
	wait "$pid" 2>/dev/null
	pid=
	limit=$((live * 3 / 2 / 1024 + 6144))
	verdict=ok
	((idle > limit)) && verdict=over
	echo "delete $how: 200000 -> $left products; RSS full $full KB, after delete $after KB, after 15 s idle $idle KB; live $((live / 1024)) KB, heap $((heap / 1024)) KB, $cycles cycles; gate 1.5 x live + 6 MB = $limit KB: $verdict" | tee -a "$OUT/delete.txt"
done
