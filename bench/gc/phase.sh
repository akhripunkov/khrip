#!/usr/bin/env bash
# Смена фазы: рост store, затем замены (этап памяти, часть 1b). Проверял
# адаптивный m сборщика: пока store только растёт, выживает всё, m удваивался
# до 8 и цель следующей сборки — 9 × живого; когда рост сменяется заменами,
# мусор копился до этой цели или до сборки по таймеру (2 минуты без сборки).
# С части 2 m всегда 1, а запас по умолчанию — 50 % (KHRIP_GC=50).
#
#   bench/gc/phase.sh <вариант> ...     khrip | khrip-gc100 (KHRIP_GC=100) |
#                                        khrip-m1, khrip-m1-gc50 (компилятор
#                                        KHC_M1, для старой библиотеки) | go
#
# Заполнение: FILL_REQ запросов по FILL_N записей (40 × 50 000) с паузой 1 с;
# затем замены: wrk2, CHURN_RATE запросов в секунду по CHURN_N записей
# (50 × 1000) CHURN_S секунд (180). RSS каждые 100 мс, журнал сборщика (у Go —
# gctrace) с временем. Строка итогов — в OUT_TSV; ряды — в OUT/<вариант>.
# Сервер на SERVER_CPUS (0,1), wrk2 на CLIENT_CPUS (2,3), порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
FILL_REQ=${FILL_REQ:-40}
FILL_N=${FILL_N:-50000}
CHURN_RATE=${CHURN_RATE:-50}
CHURN_N=${CHURN_N:-1000}
CHURN_S=${CHURN_S:-180}
OUT=${OUT:-$here/out/phase}
OUT_TSV=${OUT_TSV:-$OUT/phase.tsv}
WRK2=${WRK2:-$("$root/bench/tools/wrk2.sh")} || exit 2
mkdir -p "$OUT"
tmp=$(mktemp -d)
pid=
spid=
trap '[[ -n $spid ]] && kill $spid 2>/dev/null; [[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
mono() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }
kb() { awk -v k="$1:" '$1 == k {print $2}' "/proc/$pid/status"; }
up() {
	for _ in $(seq 500); do
		curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/stats && return 0
		sleep 0.01
	done
	return 1
}
peak_between() { awk -F'\t' -v a="$2" -v b="$3" '$2 >= a && $2 <= b && $3 > m {m = $3} END {printf "%.1f", m / 1024}' "$1"; }

[[ -f $OUT_TSV ]] || printf 'variant\titems\tlive_after_fill_mb\tm_after_fill\trss_after_fill_mb\tpeak_churn_mb\trss_end_mb\tlive_end_mb\tcycles_in_churn\tchurn_items_per_s\n' >"$OUT_TSV"
for v in "$@"; do
	o=$OUT/$v
	rm -rf "${o:?}"
	mkdir -p "$o"
	envs=(PORT=8080)
	case $v in
	khrip | khrip-gc100 | khrip-m1 | khrip-m1-gc50)
		khc=$root/build/khc
		[[ $v == khrip-m1* ]] && khc=${KHC_M1:?KHC_M1}
		KHRIP_GC_LOG=1 "$khc" -o "$tmp/server" "$here/phase.kh" || exit 1
		envs+=(KHRIP_GC_LOG=1)
		[[ $v == *-gc50 ]] && envs+=(KHRIP_GC=50)
		[[ $v == *-gc100 ]] && envs+=(KHRIP_GC=100)
		;;
	go)
		(cd "$here/phase_go" && go build -o "$tmp/server" .) || exit 1
		envs+=(GODEBUG=gctrace=1)
		;;
	*)
		echo "вариант $v?" >&2
		exit 2
		;;
	esac
	env "${envs[@]}" taskset -c "$SERVER_CPUS" "$tmp/server" 2> >(taskset -c "$CLIENT_CPUS" python3 "$root/bench/mem/ts_lines.py" >"$o/stderr.log") &
	pid=$!
	up || exit 1
	taskset -c "$CLIENT_CPUS" python3 "$root/eval/rss_sample.py" "$pid" "$o/rss.tsv" all 100 abs &
	spid=$!
	echo "== phase / $v: заполнение" >&2
	for _ in $(seq "$FILL_REQ"); do
		curl -s -o /dev/null -X POST "http://127.0.0.1:8080/fill/$FILL_N"
		sleep 1
	done
	sleep 12
	tf=$(mono)
	rss_fill=$(kb VmRSS)
	echo "== phase / $v: замены, $CHURN_RATE × $CHURN_N в секунду, $CHURN_S с" >&2
	CHURN_N=$CHURN_N CHURN_TOTAL=$((FILL_REQ * FILL_N)) taskset -c "$CLIENT_CPUS" "$WRK2" -t1 -c4 -R"$CHURN_RATE" -d"${CHURN_S}s" \
		-s "$here/phase.lua" http://127.0.0.1:8080 >"$o/wrk.txt" 2>&1
	tc=$(mono)
	rss_end=$(kb VmRSS)
	kill "$spid" 2>/dev/null
	wait "$spid" 2>/dev/null
	spid=
	read -r items live _ cycles < <(curl -s http://127.0.0.1:8080/stats)
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	pid=
	if [[ $v == go ]]; then
		# живое после заполнения — по последней строке gctrace до замен: «A->B->C MB», C — живое
		live_fill=$(awk -F'\t' -v t="$tf" '$1 <= t && $2 ~ /^gc [0-9]+ @/' "$o/stderr.log" | tail -1 | grep -oE '[0-9]+->[0-9]+->[0-9]+ MB' | awk -F'->' '{print $3 + 0}')
		m=-
		cyc=$(awk -F'\t' -v a="$tf" -v b="$tc" '$1 >= a && $1 <= b && $2 ~ /^gc [0-9]+ @/' "$o/stderr.log" | wc -l)
	else
		line=$(awk -F'\t' -v t="$tf" '$1 <= t && $2 ~ /^gc [0-9]+ \(/' "$o/stderr.log" | tail -1)
		live_fill=$(grep -o 'live [0-9.]* MB' <<<"$line" | awk '{print $2}')
		m=$(grep -o ' m [0-9]*' <<<"$line" | awk '{print $2}')
		cyc=$(awk -F'\t' -v a="$tf" -v b="$tc" '$1 >= a && $1 <= b && $2 ~ /^gc [0-9]+ \(/' "$o/stderr.log" | wc -l)
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$items" "${live_fill:--}" "${m:--}" \
		"$(awk -v k="$rss_fill" 'BEGIN {printf "%.1f", k / 1024}')" "$(peak_between "$o/rss.tsv" "$tf" "$tc")" \
		"$(awk -v k="$rss_end" 'BEGIN {printf "%.1f", k / 1024}')" "$(awk -v b="${live:-0}" 'BEGIN {printf "%.1f", b / 1048576}')" \
		"$cyc" $((CHURN_RATE * CHURN_N)) | tee -a "$OUT_TSV"
	rm -f "$tmp/server"
done
