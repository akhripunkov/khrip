#!/usr/bin/env bash
# Раскладка памяти под нагрузкой (этап памяти, часть 1): тот же сценарий и та
# же частота, что в RATE_MODE=1 eval/perf.sh, но
#   - Khrip собран с KHRIP_GC_LOG=1 и запущен под strace (только mmap, munmap,
#     mremap): снимок bench/mem/khrip_rss.py на SNAP_AT-й секунде замера (у
#     конца, где RSS накапливающих сценариев выше всего) и ещё один после
#     простоя IDLE с (сборка простоя возвращает все свободные страницы, её
#     «live» — живые данные store после всех запросов);
#   - Go — копия решения с bench/mem/go_memstats.go: после замера SIGUSR1 —
#     runtime.MemStats до и после принудительной сборки (HeapAlloc после неё —
#     живая куча тех же данных).
#
#   bench/mem/attr.sh <сценарий> [язык ...]      (по умолчанию khrip go)
#
# Окружение: RATE (по умолчанию из eval/load/rates.tsv), WARMUP (60), DURATION
# (60), SNAP_AT (56), IDLE (15), OUT (bench/mem/out/<сценарий>), EVAL_DB_PREFIX.
# Сервер на ядрах SERVER_CPUS, wrk2 на CLIENT_CPUS, порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
ev=$root/eval
. "$ev/server.sh"
sc=${1:?сценарий}
shift
langs=${*:-khrip go}
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
WARMUP=${WARMUP:-60}
DURATION=${DURATION:-60}
SNAP_AT=${SNAP_AT:-56}
IDLE=${IDLE:-15}
OUT=${OUT:-$here/out/$sc}
rate=${RATE:-$(awk -v s="$sc" '$1 !~ /^#/ && $1 == s {print $2}' "$ev/load/rates.tsv")}
[[ -n $rate ]] || { echo "нет частоты для $sc" >&2; exit 2; }
WRK2=${WRK2:-$("$root/bench/tools/wrk2.sh")} || exit 2
export LOAD_DIR=$ev/load
mkdir -p "$OUT"
tmp=$(mktemp -d)
pid=
tpid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; [[ -n $tpid ]] && kill $tpid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

task=$sc
[[ $sc == login ]] && task=notes
[[ $sc == patch ]] && task=catalog
db=0
[[ -f "$ev/tasks/$task/db" ]] && db=1
rss_kb() { awk '/^VmRSS:/ {print $2}' "/proc/$pid/status"; }
hwm_kb() { awk '/^VmHWM:/ {print $2}' "/proc/$pid/status"; }
wrk() { taskset -c "$CLIENT_CPUS" "$WRK2" -t2 -c64 -R"$rate" -s "$ev/load/$sc.lua" "$@" http://127.0.0.1:8080; }
seed() {
	local env_line
	env_line=$(python3 "$ev/load/seed.py" seed "$sc") || return 1
	# shellcheck disable=SC2046
	[[ -n "$env_line" ]] && export $env_line
	return 0
}
# число из последней строки журнала сборщика: live X MB
last_live() { grep -o 'live [0-9.]* MB' "$1" | tail -1 | awk '{print $2}'; }

for lang in $langs; do
	port_busy && { echo "порт 8080 занят" >&2; exit 2; }
	o=$OUT/$lang
	mkdir -p "$o"
	[[ $db == 1 ]] && { db_reset "${task}_$lang" || exit 2; }
	case $lang in
	khrip)
		KHRIP_GC_LOG=1 "$root/build/khc" -o "$tmp/server" "$ev/solutions/$task/khrip/main.kh" || exit 1
		: >"$o/gc.log"
		taskset -c "$SERVER_CPUS" strace -f --seccomp-bpf -qq -e trace=mmap,munmap,mremap -o "$o/strace.log" \
			env KHRIP_GC_LOG=1 PORT=8080 "$tmp/server" 2>"$o/gc.log" &
		tpid=$!
		for _ in $(seq 200); do
			pid=$(pgrep -P "$tpid" | head -1)
			[[ -n $pid ]] && break
			sleep 0.05
		done
		;;
	go)
		cp -r "$ev/solutions/$task/go" "$tmp/go"
		cp "$here/go_memstats.go" "$tmp/go/zz_memstats.go"
		(cd "$tmp/go" && go build -o "$tmp/server" .) || exit 1
		PORT=8080 taskset -c "$SERVER_CPUS" "$tmp/server" 2>"$o/memstats.log" &
		pid=$!
		;;
	*)
		echo "язык $lang: только khrip и go" >&2
		continue
		;;
	esac
	wait_up || { echo "не запустилось" >&2; exit 1; }
	seed || exit 1
	echo "== $sc / $lang: $rate запросов/с, seeded $(rss_kb) KB" | tee "$o/summary.txt"
	wrk -d"${WARMUP}s" >/dev/null 2>&1
	wrk -d"${DURATION}s" --latency >"$o/wrk.txt" 2>&1 &
	wpid=$!
	sleep "$SNAP_AT"
	if [[ $lang == khrip ]]; then
		# снимок под нагрузкой: живым здесь считается всё в занятых слотах;
		# живое по сборке — из снимка после простоя (те же данные: запросов
		# больше не было)
		echo "load snapshot: RSS $(rss_kb) KB, HWM $(hwm_kb) KB, live by last GC $(last_live "$o/gc.log") MB" | tee -a "$o/summary.txt"
		python3 "$here/khrip_rss.py" "$pid" --strace "$o/strace.log" --json "$o/load.json" | tee "$o/load.txt"
	else
		echo "load snapshot: RSS $(rss_kb) KB, HWM $(hwm_kb) KB" | tee -a "$o/summary.txt"
		awk '/^(Rss|Anonymous):/ {s[$1] += $2} END {for (k in s) print k, s[k], "KB"}' "/proc/$pid/smaps" >"$o/load.txt"
	fi
	wait "$wpid"
	echo "after run: RSS $(rss_kb) KB, HWM $(hwm_kb) KB; $(grep Requests/sec "$o/wrk.txt")" | tee -a "$o/summary.txt"
	if [[ $lang == go ]]; then
		kill -USR1 "$pid"
		sleep 2
		grep memstats "$o/memstats.log" | tee -a "$o/summary.txt"
		echo "after GC: RSS $(rss_kb) KB" | tee -a "$o/summary.txt"
	fi
	sleep "$IDLE"
	if [[ $lang == khrip ]]; then
		live=$(last_live "$o/gc.log")
		echo "idle ${IDLE}s: RSS $(rss_kb) KB, live by GC $live MB; $(tail -1 "$o/gc.log")" | tee -a "$o/summary.txt"
		python3 "$here/khrip_rss.py" "$pid" --strace "$o/strace.log" ${live:+--live-mb "$live"} --json "$o/idle.json" | tee "$o/idle.txt"
	else
		echo "idle ${IDLE}s: RSS $(rss_kb) KB" | tee -a "$o/summary.txt"
	fi
	python3 "$ev/load/seed.py" verify "$sc" | sed 's/^/invariant: /' | tee -a "$o/summary.txt"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	[[ -n $tpid ]] && { wait "$tpid" 2>/dev/null; tpid=; }
	pid=
	rm -rf "${tmp:?}"/*
done
