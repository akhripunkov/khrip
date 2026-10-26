#!/usr/bin/env bash
# Нагрузочный замер решений задач: скорость, задержки, память, процессор, запуск,
# размер, время сборки, инварианты под нагрузкой.
#
#   eval/perf.sh [сценарий ...]          — по умолчанию все; языки из LANGS
#
# Задачи с базой (ledger, shop, tracker): перед каждым запуском — пустая база
# (как в eval/run.sh), строки — в results/perf_db.tsv с процессором PostgreSQL
# на запрос (db_cpu_us_per_req).
#
# Сервер — на ядрах SERVER_CPUS, wrk — на CLIENT_CPUS. Перед замером сервер
# заполняется одинаковыми данными (load/seed.py), затем прогрев WARMUP и замер
# DURATION со смесью запросов из load/<сценарий>.lua. Строки результатов
# дописываются в results/perf.tsv; таблицу строит perf_table.py.
#
# RATE_MODE=1 — постоянная частота запросов, одна для всех языков (wrk2), RSS
# во времени и от числа соединений: perf_rate.sh. Без него — замкнутый цикл,
# как выше.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/server.sh"

if [[ ${RATE_MODE:-0} == 1 ]]; then
	DURATION=${DURATION:-60s}
	WARMUP=${WARMUP:-60s}
	LANGS=${LANGS:-khrip go csharp}
fi

SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
CONNECTIONS=${CONNECTIONS:-64}
DURATION=${DURATION:-10s}
WARMUP=${WARMUP:-3s}
LANGS=${LANGS:-khrip go csharp python}
OUT=${OUT:-$here/results/perf.tsv}
OUT_DB=${OUT_DB:-$here/results/perf_db.tsv}
export LOAD_DIR=$here/load WINDOW_SECONDS=1

scenarios=("$@")
[[ ${#scenarios[@]} -eq 0 ]] && scenarios=(shortener bank notes login ratelimit catalog patch inventory polls bookings ledger shop tracker)

tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

now_ms() { echo $(($(date +%s%N) / 1000000)); }
status_kb() { awk -v k="$1:" '$1 == k {print $2}' "/proc/$pid/status"; }
cpu_ticks() { awk '{print $14 + $15}' "/proc/$pid/stat"; }
# процессор всех процессов PostgreSQL (сотые доли секунды); закрытые соединения
# учтены в cutime/cstime главного процесса, который их дождался
pg_ticks() {
	local t=0 p v
	for p in $(pgrep -x postgres); do
		v=$(awk '{print $14 + $15 + $16 + $17}' "/proc/$p/stat" 2>/dev/null)
		t=$((t + ${v:-0}))
	done
	echo "$t"
}
to_ms() {
	awk -v v="$1" 'BEGIN { n = v + 0; if (v ~ /us$/) n /= 1000; else if (v ~ /ms$/) n = n;
		else if (v ~ /s$/) n *= 1000; printf "%.2f", n }'
}
stop() {
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	pid=
}
size_of() {
	case $1 in
	khrip | go) stat -c %s "$2/server" ;;
	csharp) du -sb --exclude='*.pdb' "$2/cs" | cut -f1 ;;
	python) stat -c %s "$3/main.py" ;;
	esac
}

if [[ ${RATE_MODE:-0} == 1 ]]; then
	. "$here/perf_rate.sh"
	exit
fi

[[ -f "$OUT" ]] || printf 'scenario\tlang\trps\tp50_ms\tp99_ms\terrors_pct\tidle_mb\tseeded_mb\tpeak_mb\tafter_mb\tcpu_us_per_req\tstartup_ms\tbuild_s\tsize_bytes\tinvariant\n' >"$OUT"
[[ -f "$OUT_DB" ]] || printf 'scenario\tlang\trps\tp50_ms\tp99_ms\terrors_pct\tidle_mb\tseeded_mb\tpeak_mb\tafter_mb\tcpu_us_per_req\tstartup_ms\tbuild_s\tsize_bytes\tinvariant\tdb_cpu_us_per_req\n' >"$OUT_DB"

for sc in "${scenarios[@]}"; do
	task=$sc
	[[ $sc == login ]] && task=notes
	[[ $sc == patch ]] && task=catalog
	db=0
	[[ -f "$here/tasks/$task/db" ]] && db=1
	for lang in $LANGS; do
		dir=$here/solutions/$task/$lang
		[[ -d $dir ]] || continue
		if port_busy; then
			echo "порт 8080 занят" >&2
			exit 2
		fi
		echo "== $sc / $lang" >&2
		rm -rf "${tmp:?}"/*
		t0=$(now_ms)
		build_solution "$lang" "$dir" "$tmp" || { echo "не собралось" >&2; continue; }
		build_s=$(awk -v t=$(($(now_ms) - t0)) 'BEGIN {printf "%.1f", t / 1000}')

		# запуск: медиана из трёх
		starts=()
		for _ in 1 2 3; do
			# с базой: пустая база, старт включает создание таблиц
			[[ $db == 1 ]] && { db_reset "${task}_$lang" || { echo "нет PostgreSQL" >&2; continue 2; }; }
			t0=$(now_ms)
			PIN="taskset -c $SERVER_CPUS" start_solution "$lang" "$dir" "$tmp"
			wait_up || { echo "не запустилось" >&2; stop; continue 2; }
			starts+=($(($(now_ms) - t0)))
			stop
		done
		startup=$(printf '%s\n' "${starts[@]}" | sort -n | sed -n 2p)

		[[ $db == 1 ]] && db_reset "${task}_$lang"
		PIN="taskset -c $SERVER_CPUS" start_solution "$lang" "$dir" "$tmp"
		wait_up || { stop; continue; }
		sleep 0.5
		idle=$(status_kb VmRSS)
		env_line=$(python3 "$here/load/seed.py" seed "$sc") || { echo "заполнение не удалось" >&2; stop; continue; }
		# shellcheck disable=SC2046
		[[ -n "$env_line" ]] && export $env_line
		seeded=$(status_kb VmRSS)
		wrk_cmd=(taskset -c "$CLIENT_CPUS" wrk -t2 -c"$CONNECTIONS" --latency -s "$here/load/$sc.lua" http://127.0.0.1:8080)
		"${wrk_cmd[@]}" -d"$WARMUP" >/dev/null 2>&1
		c0=$(cpu_ticks)
		g0=$(pg_ticks)
		out=$("${wrk_cmd[@]}" -d"$DURATION" 2>&1)
		c1=$(cpu_ticks)
		# закрытые в конце нагрузки соединения: их процессор попадёт к главному
		# процессу PostgreSQL, когда тот их дождётся
		[[ $db == 1 ]] && sleep 1
		g1=$(pg_ticks)
		peak=$(status_kb VmHWM)
		after=$(status_kb VmRSS)
		inv=$(python3 "$here/load/seed.py" verify "$sc")
		stop

		total=$(awk '/requests in/ {print $1}' <<<"$out")
		rps=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$out")
		p50=$(to_ms "$(awk '$1 == "50%" {print $2}' <<<"$out")")
		p99=$(to_ms "$(awk '$1 == "99%" {print $2}' <<<"$out")")
		bad=$(awk '/Non-2xx/ {n += $NF} /Socket errors/ {gsub(/,/, ""); n += $4 + $6 + $8 + $10} END {print n + 0}' <<<"$out")
		err_pct=$(awk -v b="$bad" -v t="$total" 'BEGIN {printf "%.1f", t ? 100 * b / t : 0}')
		cpu_us=$(awk -v c=$((c1 - c0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
		mb() { awk -v k="$1" 'BEGIN {printf "%.1f", k / 1024}'; }
		line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$sc" "$lang" "$rps" "$p50" "$p99" "$err_pct" \
			"$(mb "$idle")" "$(mb "$seeded")" "$(mb "$peak")" "$(mb "$after")" "$cpu_us" "$startup" "$build_s" "$(size_of "$lang" "$tmp" "$dir")" "$inv")
		if [[ $db == 1 ]]; then
			db_us=$(awk -v c=$((g1 - g0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
			printf '%s\t%s\n' "$line" "$db_us" | tee -a "$OUT_DB"
		else
			printf '%s\n' "$line" | tee -a "$OUT"
		fi
	done
done
