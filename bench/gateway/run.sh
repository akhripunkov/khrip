#!/usr/bin/env bash
# Шлюз к медленному сервису: GET /quote?id= → запрос к UPSTREAM, разбор JSON,
# ответ. Одно и то же на Khrip, Go, C# и Python (bench/gateway/<язык>).
#
#   bench/gateway/run.sh [slow|fast ...]
#
# slow — сервис отвечает через 100 мс, 1000 одновременных клиентов: сколько
#        ждущих запросов держит шлюз и сколько памяти они стоят;
# fast — сервис отвечает сразу, 64 клиента: сколько стоит один проход через шлюз.
# Шлюз — на ядрах 0,1; сервис (Khrip, 1 поток) — на ядре 2; wrk — на ядре 3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
. "$root/eval/server.sh"
LANGS=${LANGS:-khrip go csharp python}
DURATION=${DURATION:-10s}
scenarios=("$@")
[[ ${#scenarios[@]} -eq 0 ]] && scenarios=(slow fast)

tmp=$(mktemp -d)
pid=
up_pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; [[ -n $up_pid ]] && kill $up_pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

"$root/build/khc" -o "$tmp/upstream" "$here/upstream.kh" || exit 1
export UPSTREAM=http://127.0.0.1:9090

status_kb() { awk -v k="$1:" '$1 == k {print $2}' "/proc/$pid/status"; }
# память процесса и его потомков (dotnet и uvicorn — один процесс)
cpu_ticks() { awk '{print $14 + $15}' "/proc/$pid/stat"; }
to_ms() {
	awk -v v="$1" 'BEGIN { n = v + 0; if (v ~ /us$/) n /= 1000; else if (v ~ /ms$/) n = n;
		else if (v ~ /s$/) n *= 1000; printf "%.1f", n }'
}

printf 'сценарий\tязык\tзапросов/с\tp50 мс\tp99 мс\tошибок\tмкс ЦП шлюза на запрос\tпик памяти МБ\n'
for sc in "${scenarios[@]}"; do
	delay=0 conns=64
	[[ $sc == slow ]] && delay=100 conns=1000
	DELAY=$delay PORT=9090 THREADS=1 taskset -c 2 "$tmp/upstream" 2>/dev/null &
	up_pid=$!
	for lang in $LANGS; do
		dir=$here/$lang
		rm -rf "${tmp:?}/$lang" && mkdir -p "$tmp/$lang"
		build_solution "$lang" "$dir" "$tmp/$lang" || { echo "$lang: не собралось" >&2; continue; }
		PIN="taskset -c 0,1" start_solution "$lang" "$dir" "$tmp/$lang"
		wait_up || { echo "$lang: не запустилось" >&2; kill "$pid"; continue; }
		curl -s -o /dev/null "http://127.0.0.1:8080/quote?id=1"
		taskset -c 3 wrk -t1 -c"$conns" -d3s -s "$here/quote.lua" http://127.0.0.1:8080 >/dev/null 2>&1
		c0=$(cpu_ticks)
		out=$(taskset -c 3 wrk -t1 -c"$conns" -d"$DURATION" --timeout 10s --latency -s "$here/quote.lua" http://127.0.0.1:8080 2>&1)
		c1=$(cpu_ticks)
		peak=$(status_kb VmHWM)
		kill "$pid"
		wait "$pid" 2>/dev/null
		pid=
		total=$(awk '/requests in/ {print $1}' <<<"$out")
		rps=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$out")
		p50=$(to_ms "$(awk '$1 == "50%" {print $2}' <<<"$out")")
		p99=$(to_ms "$(awk '$1 == "99%" {print $2}' <<<"$out")")
		bad=$(awk '/Non-2xx/ {n += $NF} /Socket errors/ {gsub(/,/, ""); n += $4 + $6 + $8 + $10} END {print n + 0}' <<<"$out")
		cpu=$(awk -v c=$((c1 - c0)) -v t="$total" 'BEGIN {printf "%.1f", t ? c * 10000 / t : 0}')
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sc" "$lang" "$rps" "$p50" "$p99" "$bad" "$cpu" "$(awk -v k="$peak" 'BEGIN {printf "%.1f", k / 1024}')"
	done
	kill "$up_pid"
	wait "$up_pid" 2>/dev/null
	up_pid=
done
