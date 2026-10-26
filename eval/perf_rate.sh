# Замер при постоянной частоте запросов (eval/perf.sh, RATE_MODE=1); файл
# подключается из perf.sh и пользуется его функциями (сборка, запуск, база).
#
#   RATE_MODE=1 eval/perf.sh [сценарий ...]
#       каждый сервер получает одну и ту же частоту запросов из load/rates.tsv
#       (wrk2 -R, открытый цикл); прогрев WARMUP (60 с), замер DURATION (60 с);
#       RSS каждые RSS_MS (100) мс всё время прогрева и замера — в
#       RSS_DIR/<сценарий>-<язык>.tsv; строка итогов — в results/perf_rate.tsv
#   RATE_MODE=1 CONN_SCALE="64 1000 10000" eval/perf.sh [сценарий ...]
#       память от числа соединений: на каждое N — свой сервер, прогрев на 64
#       соединениях, затем N соединений при низкой частоте SCALE_RATE (1000);
#       RSS — среднее и пик за последние SCALE_WINDOW (30) с, когда все
#       соединения открыты; строки — в results/perf_conn.tsv
#
# Частота — общая для всех языков (по умолчанию khrip go csharp): ≈ 70 %
# максимума Go в замкнутом цикле на этой машине (как выбрана — в rates.tsv).
# RATE=<запросов/с> задаёт одну частоту всем сценариям. Python этих частот не
# держит: он идёт, только если указан в LANGS и задан RATE_PYTHON, — для
# сведения, не для сравнения.
#
# Достигнутая частота — Requests/sec wrk2; если она ниже заданной больше чем на
# BEHIND_PCT (2) %, строка помечена behind. Задержки — из wrk2 (Recorded
# Latency: с поправкой на координированное упущение; wrk2 считает их после
# калибровки, первые ≈ 10 с замера не входят).

RATES=${RATES:-$here/load/rates.tsv}
OUT_RATE=${OUT_RATE:-$here/results/perf_rate.tsv}
OUT_CONN=${OUT_CONN:-$here/results/perf_conn.tsv}
RSS_DIR=${RSS_DIR:-$here/results/rss}
RSS_MS=${RSS_MS:-100}
SLOPE_WINDOW=${SLOPE_WINDOW:-30}
BEHIND_PCT=${BEHIND_PCT:-2}
CONN_SCALE=${CONN_SCALE:-}
SCALE_RATE=${SCALE_RATE:-1000}
SCALE_WARMUP=${SCALE_WARMUP:-30s}
SCALE_WINDOW=${SCALE_WINDOW:-30}
WRK2=${WRK2:-$("$here/../bench/tools/wrk2.sh")} || { echo "нет wrk2 (bench/tools/wrk2.sh)" >&2; exit 2; }
mkdir -p "$RSS_DIR"

spid=
wpid=
trap '[[ -n $spid ]] && kill $spid 2>/dev/null; [[ -n $wpid ]] && kill $wpid 2>/dev/null; [[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

# частота сценария: RATE для всех, иначе вторая колонка rates.tsv
rate_of() {
	if [[ -n ${RATE:-} ]]; then
		echo "$RATE"
		return
	fi
	awk -v s="$1" '$1 !~ /^#/ && $1 == s {print $2}' "$RATES"
}
# время из wrk2 (1.23ms, 512.00us, 1.02s, 2.00m) — в миллисекундах
lat_ms() {
	awk -v v="$1" 'BEGIN { n = v + 0; if (v ~ /us$/) n /= 1000; else if (v ~ /ms$/) n = n;
		else if (v ~ /s$/) n *= 1000; else if (v ~ /m$/) n *= 60000; else if (v ~ /h$/) n *= 3600000;
		if (v == "") printf "-"; else printf "%.2f", n }'
}
pct_of() { lat_ms "$(awk -v p="$1" '$1 == p {print $2; exit}' <<<"$2")"; }
# выборка RSS сервера в фоне: sampler_start <файл> <фаза>, sampler_stop
sampler_start() {
	taskset -c "$CLIENT_CPUS" python3 "$here/rss_sample.py" "$pid" "$1" "$2" "$RSS_MS" &
	spid=$!
}
sampler_stop() {
	[[ -n $spid ]] && kill "$spid" 2>/dev/null
	wait "$spid" 2>/dev/null
	spid=
}
# запуск сервера с пустой базой и данными seed.py; → idle, seeded (КБ)
fresh_server() {
	local lang=$1 dir=$2 sc=$3
	[[ $db == 1 ]] && { db_reset "${task}_$lang" || { echo "нет PostgreSQL" >&2; return 1; }; }
	PIN="taskset -c $SERVER_CPUS" start_solution "$lang" "$dir" "$tmp"
	wait_up || { echo "не запустилось" >&2; stop; return 1; }
	sleep 0.5
	idle=$(status_kb VmRSS)
	env_line=$(python3 "$here/load/seed.py" seed "$sc") || { echo "заполнение не удалось" >&2; stop; return 1; }
	# shellcheck disable=SC2046
	[[ -n "$env_line" ]] && export $env_line
	seeded=$(status_kb VmRSS)
}
mb() { awk -v k="$1" 'BEGIN {printf "%.1f", k / 1024}'; }
errors_pct() {
	local out=$1 total bad
	total=$(awk '/requests in/ {print $1}' <<<"$out")
	bad=$(awk '/Non-2xx/ {n += $NF} /Socket errors/ {gsub(/,/, ""); n += $4 + $6 + $8 + $10} END {print n + 0}' <<<"$out")
	awk -v b="$bad" -v t="$total" 'BEGIN {printf "%.1f", t ? 100 * b / t : 0}'
}

[[ -f "$OUT_RATE" ]] || printf 'scenario\tlang\trate\tachieved_rps\tbehind\terrors_pct\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tidle_mb\tseeded_mb\trss_peak_mb\trss_mean_mb\trss_last_mb\trss_slope_mb_s\thwm_mb\tafter_mb\tcpu_us_per_req\tdb_cpu_us_per_req\tconnections\twarmup\tduration\tbuild_s\tsize_bytes\tinvariant\n' >"$OUT_RATE"
if [[ -n $CONN_SCALE ]]; then
	ulimit -n 20000 2>/dev/null || ulimit -n "$(ulimit -Hn)"
	[[ -f "$OUT_CONN" ]] || printf 'scenario\tlang\tconnections\trate\tachieved_rps\tbehind\terrors_pct\tp99_ms\tserver_fds\trss_mean_mb\trss_peak_mb\trss_last_mb\thwm_mb\tseeded_mb\tinvariant\n' >"$OUT_CONN"
fi

for sc in "${scenarios[@]}"; do
	task=$sc
	[[ $sc == login ]] && task=notes
	[[ $sc == patch ]] && task=catalog
	db=0
	[[ -f "$here/tasks/$task/db" ]] && db=1
	for lang in $LANGS; do
		dir=$here/solutions/$task/$lang
		[[ -d $dir ]] || continue
		if [[ -n $CONN_SCALE ]]; then
			rate=$SCALE_RATE
		elif [[ $lang == python ]]; then
			rate=${RATE_PYTHON:-}
		else
			rate=$(rate_of "$sc")
		fi
		[[ -n $rate ]] || { echo "== $sc / $lang: нет частоты — пропущен" >&2; continue; }
		if port_busy; then
			echo "порт 8080 занят" >&2
			exit 2
		fi
		rm -rf "${tmp:?}"/*
		t0=$(now_ms)
		build_solution "$lang" "$dir" "$tmp" || { echo "не собралось" >&2; continue; }
		build_s=$(awk -v t=$(($(now_ms) - t0)) 'BEGIN {printf "%.1f", t / 1000}')
		wrk_base=(taskset -c "$CLIENT_CPUS" "$WRK2" -t2 -R"$rate" -s "$here/load/$sc.lua")

		if [[ -n $CONN_SCALE ]]; then
			for n in $CONN_SCALE; do
				echo "== $sc / $lang: $n соединений, $rate запросов/с" >&2
				fresh_server "$lang" "$dir" "$sc" || continue
				samples=$RSS_DIR/conn-$sc-$lang-$n.tsv
				: >"$samples"
				sampler_start "$samples" warmup
				"${wrk_base[@]}" -c64 -d"$SCALE_WARMUP" http://127.0.0.1:8080 >/dev/null 2>&1
				sampler_stop
				# wrk2 открывает соединения потока через 5 мс одно за другим и
				# калибруется 10 с после этого; окно RSS — последние SCALE_WINDOW с
				open_s=$(((n / 2 * 5 + 999) / 1000))
				dur=$((open_s + 15 + SCALE_WINDOW))
				sampler_start "$samples" run
				# --timeout: при редких запросах на соединение wrk2 иначе считает
				# ожидание следующего запроса таймаутом
				"${wrk_base[@]}" -c"$n" -d"${dur}s" --timeout 120s --latency http://127.0.0.1:8080 >"$tmp/wrk.out" 2>&1 &
				wpid=$!
				sleep $((dur - 5))
				# открытые дескрипторы сервера: соединения, слушающий сокет, epoll, база
				fds=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
				wait "$wpid"
				wpid=
				sampler_stop
				out=$(cat "$tmp/wrk.out")
				hwm=$(status_kb VmHWM)
				inv=$(python3 "$here/load/seed.py" verify "$sc")
				stop
				printf '%s\n' "$out" >"$RSS_DIR/conn-$sc-$lang-$n.wrk.txt"
				read -r _ _ last _ wpeak wmean < <(python3 "$here/rss_sample.py" --stats "$samples" run "$SCALE_WINDOW")
				achieved=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$out")
				# соединение начинает слать запросы, когда открыто: в среднем через
				# N · 1,25 мс от начала (по N/2 на поток через 5 мс), — ожидаемая
				# средняя частота за прогон на столько же ниже
				behind=$(awk -v a="${achieved:-0}" -v r="$rate" -v p="$BEHIND_PCT" -v n="$n" -v d="$dur" \
					'BEGIN {e = r * (1 - n * 0.00125 / d); print (a < e * (1 - p / 100)) ? "behind" : "ok"}')
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sc" "$lang" "$n" "$rate" "${achieved:--}" "$behind" \
					"$(errors_pct "$out")" "$(pct_of 99.000% "$out")" "$fds" "$wmean" "$wpeak" "$last" "$(mb "$hwm")" "$(mb "$seeded")" "$inv" | tee -a "$OUT_CONN"
			done
			continue
		fi

		echo "== $sc / $lang: $rate запросов/с" >&2
		fresh_server "$lang" "$dir" "$sc" || continue
		samples=$RSS_DIR/$sc-$lang.tsv
		: >"$samples"
		sampler_start "$samples" warmup
		"${wrk_base[@]}" -c"$CONNECTIONS" -d"$WARMUP" http://127.0.0.1:8080 >/dev/null 2>&1
		sampler_stop
		c0=$(cpu_ticks)
		g0=$(pg_ticks)
		sampler_start "$samples" run
		out=$("${wrk_base[@]}" -c"$CONNECTIONS" -d"$DURATION" --latency http://127.0.0.1:8080 2>&1)
		sampler_stop
		c1=$(cpu_ticks)
		[[ $db == 1 ]] && sleep 1
		g1=$(pg_ticks)
		hwm=$(status_kb VmHWM)
		after=$(status_kb VmRSS)
		inv=$(python3 "$here/load/seed.py" verify "$sc")
		stop
		printf '%s\n' "$out" >"$RSS_DIR/$sc-$lang.wrk.txt"

		total=$(awk '/requests in/ {print $1}' <<<"$out")
		achieved=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$out")
		behind=$(awk -v a="${achieved:-0}" -v r="$rate" -v p="$BEHIND_PCT" 'BEGIN {print (a < r * (1 - p / 100)) ? "behind" : "ok"}')
		cpu_us=$(awk -v c=$((c1 - c0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
		db_us=-
		[[ $db == 1 ]] && db_us=$(awk -v c=$((g1 - g0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
		read -r peak mean last slope _ < <(python3 "$here/rss_sample.py" --stats "$samples" run "$SLOPE_WINDOW")
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$sc" "$lang" "$rate" "${achieved:--}" "$behind" "$(errors_pct "$out")" \
			"$(pct_of 50.000% "$out")" "$(pct_of 90.000% "$out")" "$(pct_of 99.000% "$out")" "$(pct_of 99.900% "$out")" "$(pct_of 100.000% "$out")" \
			"$(mb "$idle")" "$(mb "$seeded")" "$peak" "$mean" "$last" "$slope" "$(mb "$hwm")" "$(mb "$after")" \
			"$cpu_us" "$db_us" "$CONNECTIONS" "$WARMUP" "$DURATION" "$build_s" "$(size_of "$lang" "$tmp" "$dir")" "$inv" | tee -a "$OUT_RATE"
	done
done
