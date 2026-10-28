#!/usr/bin/env bash
# Долгий замер при одинаковой частоте (этап памяти, часть 1b): RSS к
# установившемуся режиму, живое в конце, число сборок, процессор на запрос и
# ловушка пауз (bench/mem/stall_probe.py) — у всех вариантов одинаково.
#
#   bench/mem/long.sh <сценарий> <вариант> ...
#
# Варианты:
#   khrip          — обычная сборка (с KHRIP_GC_LOG=1: строка о каждой сборке)
#   khrip-gcoff    — то же с KHRIP_GC=off
#   khrip-gc100    — то же с KHRIP_GC=100 (запас до части 2)
#   khrip-m1       — компилятор KHC_M1: копия библиотеки, где m всегда 1
#                    (в репозиторий не входит)
#   khrip-m1-gc50  — то же с KHRIP_GC=50
#   go             — копия решения с bench/mem/go_memstats.go, GODEBUG=gctrace=1
#
# Окружение: RATE (по умолчанию из eval/load/rates.tsv), WARMUP (60 с),
# DURATION (600 с), IDLE_MAX (180 с — сколько ждать первой сборки Khrip после
# замера: её «live» — живое в конце), OUT (bench/mem/out/long/<сценарий>), OUT_TSV
# (bench/mem/out/long.tsv), PROBE (1 — ловушка пауз), SERVER_CPUS (0,1),
# CLIENT_CPUS (2,3). Только сценарии без базы.
#
# В OUT/<вариант>: rss.tsv (фаза, мс CLOCK_MONOTONIC, RSS КБ; каждые 100 мс),
# stderr.log (строки сервера с временем: журнал сборщика, gctrace),
# memstats.log (Go), wrk.txt, probe.tsv, threads.tsv, summary.txt, cpu.tsv
# (кража гипервизора по ядрам и процессор потоков сервера каждые 50 мс,
# bench/mem/cpu_trace.py), gaps.1 и gaps.2 (щели в отправке у потоков wrk2,
# bench/mem/gaps.lua), run.txt (границы замера). Строка итогов — в OUT_TSV.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
ev=$root/eval
. "$ev/server.sh"
sc=${1:?сценарий}
shift
variants=${*:?варианты}
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
WARMUP=${WARMUP:-60}
DURATION=${DURATION:-600}
IDLE_MAX=${IDLE_MAX:-180}
PROBE=${PROBE:-1}
OUT=${OUT:-$here/out/long/$sc}
OUT_TSV=${OUT_TSV:-$here/out/long.tsv}
rate=${RATE:-$(awk -v s="$sc" '$1 !~ /^#/ && $1 == s {print $2}' "$ev/load/rates.tsv")}
[[ -n $rate ]] || { echo "нет частоты для $sc" >&2; exit 2; }
WRK2=${WRK2:-$("$root/bench/tools/wrk2.sh")} || exit 2
export LOAD_DIR=$ev/load WINDOW_SECONDS=1
mkdir -p "$OUT" "$(dirname "$OUT_TSV")"
tmp=$(mktemp -d)
pid=
spid=
ppid_=
cpid=
trap '[[ -n $spid ]] && kill $spid 2>/dev/null; [[ -n $ppid_ ]] && kill $ppid_ 2>/dev/null; [[ -n $cpid ]] && kill $cpid 2>/dev/null; [[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

mono() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }
kb() { awk -v k="$1:" '$1 == k {print $2}' "/proc/$pid/status"; }
ticks() { awk '{print $14 + $15}' "/proc/$pid/stat"; }
lat() {
	awk -v p="$1" '$1 == p {v = $2; n = v + 0; if (v ~ /us$/) n /= 1000; else if (v ~ /ms$/) n = n;
		else if (v ~ /s$/) n *= 1000; else if (v ~ /m$/) n *= 60000; printf "%.2f", n; exit}' "$2"
}
sampler() {
	taskset -c "$CLIENT_CPUS" python3 "$ev/rss_sample.py" "$pid" "$1" "$2" 100 abs &
	spid=$!
}
sampler_stop() {
	kill "$spid" 2>/dev/null
	wait "$spid" 2>/dev/null
	spid=
}

[[ -f $OUT_TSV ]] || printf 'scenario\tvariant\trate\tachieved_rps\tbehind\tp50_ms\tp99_ms\tp999_ms\tmax_ms\trss_peak_mb\trss_mean_last300_mb\trss_last_mb\trss_slope_last300_mb_s\thwm_mb\tlive_end_mb\tgc_total\tgc_in_run\tcpu_us_per_req\tprobe_max_ms\twarmup_s\tduration_s\n' >"$OUT_TSV"

for v in $variants; do
	port_busy && { echo "порт 8080 занят" >&2; exit 2; }
	o=$OUT/$v
	rm -rf "${o:?}"
	mkdir -p "$o"
	envs=(PORT=8080)
	case $v in
	khrip | khrip-gcoff | khrip-gc100 | khrip-m1 | khrip-m1-gc50)
		khc=$root/build/khc
		[[ $v == khrip-m1* ]] && khc=${KHC_M1:?KHC_M1 — компилятор с копией библиотеки, где m = 1}
		KHRIP_GC_LOG=1 "$khc" -o "$tmp/server" "$ev/solutions/$sc/khrip/main.kh" || exit 1
		envs+=(KHRIP_GC_LOG=1)
		[[ $v == khrip-gcoff ]] && envs+=(KHRIP_GC=off)
		[[ $v == *-gc50 ]] && envs+=(KHRIP_GC=50)
		[[ $v == khrip-gc100 ]] && envs+=(KHRIP_GC=100)
		;;
	go)
		rm -rf "${tmp:?}/go"
		cp -r "$ev/solutions/$sc/go" "$tmp/go"
		cp "$here/go_memstats.go" "$tmp/go/zz_memstats.go"
		(cd "$tmp/go" && go build -o "$tmp/server" .) || exit 1
		envs+=(GODEBUG=gctrace=1)
		;;
	*)
		echo "вариант $v?" >&2
		exit 2
		;;
	esac
	env "${envs[@]}" taskset -c "$SERVER_CPUS" "$tmp/server" 2> >(taskset -c "$CLIENT_CPUS" python3 "$here/ts_lines.py" >"$o/stderr.log") &
	pid=$!
	wait_up || { echo "не запустилось" >&2; exit 1; }
	env_line=$(python3 "$ev/load/seed.py" seed "$sc") || exit 1
	# shellcheck disable=SC2046
	[[ -n "$env_line" ]] && export $env_line
	echo "== $sc / $v: $rate запросов/с, прогрев $WARMUP с, замер $DURATION с" >&2
	if [[ $PROBE == 1 ]]; then
		taskset -c "$CLIENT_CPUS" python3 "$here/stall_probe.py" "$pid" "$o" &
		ppid_=$!
		taskset -c "$CLIENT_CPUS" python3 "$here/cpu_trace.py" "$pid" "$o/cpu.tsv" &
		cpid=$!
	fi
	# сценарий — через обёртку: щели в отправке у потоков wrk2 (gaps.lua)
	export GAPS_SCENARIO=$ev/load/$sc.lua GAPS_OUT=$o/gaps
	wrk=(taskset -c "$CLIENT_CPUS" "$WRK2" -t2 -c64 -R"$rate" -s "$here/gaps.lua")
	sampler "$o/rss.tsv" warmup
	"${wrk[@]}" -d"${WARMUP}s" http://127.0.0.1:8080 >"$o/wrk-warmup.txt" 2>&1
	sampler_stop
	t0=$(mono)
	c0=$(ticks)
	sampler "$o/rss.tsv" run
	"${wrk[@]}" -d"${DURATION}s" --latency http://127.0.0.1:8080 >"$o/wrk.txt" 2>&1
	c1=$(ticks)
	t1=$(mono)
	sampler_stop
	hwm=$(kb VmHWM)
	echo "run $t0 $t1" >"$o/run.txt"
	live=-
	if [[ $v == go ]]; then
		kill -USR1 "$pid"
		for _ in $(seq 100); do
			grep -q 'memstats after-gc' "$o/stderr.log" && break
			sleep 0.2
		done
		live=$(awk '/memstats after-gc/ {for (i = 1; i <= NF; i++) if ($i ~ /^heap_alloc=/) {split($i, a, "="); printf "%.1f", a[2] / 1048576}}' "$o/stderr.log" | tail -1)
		gc_total=$(awk -F'\t' -v t="$t1" '$1 <= t && $2 ~ /^gc [0-9]+ @/' "$o/stderr.log" | wc -l)
		gc_run=$(awk -F'\t' -v a="$t0" -v t="$t1" '$1 >= a && $1 <= t && $2 ~ /^gc [0-9]+ @/' "$o/stderr.log" | wc -l)
	else
		# первая сборка после замера — простоя (через 10 с без выделений store)
		# или по таймеру (forced: store меняли, а сборки не было 2 минуты); у
		# большой кучи разметка идёт четвертью времени — ждём её строку
		for _ in $(seq $((IDLE_MAX * 5))); do
			awk -F'\t' -v t="$t1" '$1 > t && $2 ~ /^gc [0-9]+ \(/ {f = 1} END {exit !f}' "$o/stderr.log" && break
			[[ $v == khrip-gcoff ]] && break
			sleep 0.2
		done
		live=$(awk -F'\t' -v t="$t1" '$1 > t && $2 ~ /^gc [0-9]+ \(/' "$o/stderr.log" | head -1 | grep -o 'live [0-9.]* MB' | awk '{print $2}')
		gc_total=$(awk -F'\t' -v t="$t1" '$1 <= t && $2 ~ /^gc [0-9]+ \(/' "$o/stderr.log" | wc -l)
		gc_run=$(awk -F'\t' -v a="$t0" -v t="$t1" '$1 >= a && $1 <= t && $2 ~ /^gc [0-9]+ \(/' "$o/stderr.log" | wc -l)
	fi
	echo "idle RSS $(kb VmRSS) KB" >>"$o/run.txt"
	python3 "$ev/load/seed.py" verify "$sc" >>"$o/run.txt"
	if [[ -n $ppid_ ]]; then
		kill "$ppid_" 2>/dev/null
		wait "$ppid_" 2>/dev/null
		ppid_=
	fi
	if [[ -n $cpid ]]; then
		kill "$cpid" 2>/dev/null
		wait "$cpid" 2>/dev/null
		cpid=
	fi
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	pid=
	total=$(awk '/requests in/ {print $1}' "$o/wrk.txt")
	achieved=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' "$o/wrk.txt")
	behind=$(awk -v a="${achieved:-0}" -v r="$rate" 'BEGIN {print (a < r * 0.98) ? "behind" : "ok"}')
	cpu=$(awk -v c=$((c1 - c0)) -v t="${total:-0}" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
	read -r peak _ last slope _ wmean < <(python3 "$ev/rss_sample.py" --stats "$o/rss.tsv" run 300)
	pmax=$(grep -o 'max [0-9.]*' "$o/summary.txt" 2>/dev/null | awk '{print $2}' | tail -1)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$sc" "$v" "$rate" "${achieved:--}" "$behind" "$(lat 50.000% "$o/wrk.txt")" "$(lat 99.000% "$o/wrk.txt")" \
		"$(lat 99.900% "$o/wrk.txt")" "$(lat 100.000% "$o/wrk.txt")" "$peak" "$wmean" "$last" "$slope" \
		"$(awk -v k="$hwm" 'BEGIN {printf "%.1f", k / 1024}')" "${live:--}" "$gc_total" "$gc_run" "$cpu" "${pmax:--}" \
		"$WARMUP" "$DURATION" | tee -a "$OUT_TSV"
	rm -f "$tmp/server"
done
