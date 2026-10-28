#!/usr/bin/env bash
# ab.sh <сценарий> <кругов> <out.tsv> <вариант>... — замкнутый цикл, как eval/perf.sh,
# для нескольких серверов по кругу (порядок в каждом круге сдвигается)
#
# Вариант — путь к собранному серверу Khrip или слово csharp (eval/solutions/
# <задача>/csharp, собирается один раз). Каждый прогон: свежий сервер на ядрах
# SERVER_CPUS (0,1), заполнение load/seed.py, прогрев WARMUP (3 с) и замер
# DURATION (10 с) wrk -t2 -c64 на ядрах 2,3 со смесью eval/load/<сценарий>.lua
# (или LUA — другой сценарий wrk), процессор сервера из /proc. Строка:
# круг, сценарий, вариант, запросов/с, p50, p99 (мс), процессор на запрос (мкс),
# доля не-2xx (%). Запускать под bench/tools/quiet.sh.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
sc=$1; rounds=$2; out=$3; shift 3
variants=("$@")
task=$sc
[[ $sc == patch ]] && task=catalog
SERVER_CPUS=${SERVER_CPUS:-0,1}
WARMUP=${WARMUP:-3s}
DURATION=${DURATION:-10s}
lua=${LUA:-$root/eval/load/$sc.lua}
cs=${CS_DIR:-${TMPDIR:-/tmp}/ab-cs-$task}
if pgrep -x wrk >/dev/null || pgrep -f '^(/usr)?(/bin/)?bash [^ ]*(perf|run)\.sh' >/dev/null; then
	echo "ab.sh: идёт другой замер" >&2
	exit 2
fi
for v in "${variants[@]}"; do
	if [[ $v == csharp && ! -f $cs/App.dll ]]; then
		dotnet publish "$root/eval/solutions/$task/csharp" -c Release -o "$cs" --nologo -v q >/dev/null || exit 1
		dotnet build-server shutdown >/dev/null 2>&1
	fi
done
[[ -f $out ]] || printf 'round\tscenario\tvariant\trps\tp50_ms\tp99_ms\tcpu_us_per_req\tnon2xx_pct\n' >"$out"
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null' EXIT
to_ms() {
	awk -v v="$1" 'BEGIN { n = v + 0; if (v ~ /us$/) n /= 1000; else if (v ~ /ms$/) n = n;
		else if (v ~ /s$/) n *= 1000; printf "%.2f", n }'
}
n=${#variants[@]}
for r in $(seq "$rounds"); do
	for k in $(seq 0 $((n - 1))); do
		v=${variants[$(((k + r - 1) % n))]}
		if [[ $v == csharp ]]; then
			ASPNETCORE_URLS=http://127.0.0.1:8080 Logging__LogLevel__Default=Warning taskset -c "$SERVER_CPUS" dotnet "$cs/App.dll" >/dev/null &
		else
			PORT=8080 taskset -c "$SERVER_CPUS" "$v" 2>/dev/null &
		fi
		pid=$!
		for _ in $(seq 3000); do
			curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/ && break
			sleep 0.01
		done
		sleep 0.5
		(cd "$root/eval" && python3 load/seed.py seed "$sc" >/dev/null) || { echo "seed failed: $v" >&2; kill $pid; wait $pid; pid=; continue; }
		wrk_cmd=(taskset -c 2,3 wrk -t2 -c64 --latency -s "$lua" http://127.0.0.1:8080)
		LOAD_DIR=$root/eval/load WINDOW_SECONDS=1 "${wrk_cmd[@]}" -d"$WARMUP" >/dev/null 2>&1
		c0=$(awk '{print $14 + $15}' /proc/$pid/stat)
		o=$(LOAD_DIR=$root/eval/load WINDOW_SECONDS=1 "${wrk_cmd[@]}" -d"$DURATION" 2>&1)
		c1=$(awk '{print $14 + $15}' /proc/$pid/stat)
		kill $pid
		wait $pid 2>/dev/null
		pid=
		total=$(awk '/requests in/ {print $1}' <<<"$o")
		rps=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$o")
		p50=$(to_ms "$(awk '$1 == "50%" {print $2}' <<<"$o")")
		p99=$(to_ms "$(awk '$1 == "99%" {print $2}' <<<"$o")")
		bad=$(awk '/Non-2xx/ {n += $NF} END {print n + 0}' <<<"$o")
		cpu=$(awk -v c=$((c1 - c0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
		e=$(awk -v b="$bad" -v t="$total" 'BEGIN {printf "%.1f", t ? 100 * b / t : 0}')
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$sc" "$(basename "$v")" "$rps" "$p50" "$p99" "$cpu" "$e" | tee -a "$out"
	done
done
