#!/usr/bin/env bash
# Замеры HTTP-серверов: Khrip, Go (net/http), C# (ASP.NET Core, JIT и Native AOT).
#
# Сервер и нагрузочный клиент (wrk) живут на разных ядрах, чтобы не мешать друг другу.
# Для каждого сценария делается прогрев, затем RUNS прогонов; в таблицу идёт прогон
# с медианным RPS. Перед замером проверяется, что сервер отвечает правильным телом.
#
# Использование: ./run.sh [khrip|go|csharp|csharp-aot ...]   (по умолчанию — все)
# Параметры через окружение: SERVER_CPUS, CLIENT_CPUS, CONNECTIONS, THREADS,
#                            DURATION, WARMUP, RUNS, PORT, LABEL (добавляется к имени
#                            файла с результатами).
set -euo pipefail
cd "$(dirname "$0")"

SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}
CONNECTIONS=${CONNECTIONS:-128}
THREADS=${THREADS:-2}
DURATION=${DURATION:-10s}
WARMUP=${WARMUP:-5s}
RUNS=${RUNS:-3}
PORT=${PORT:-8080}
BUILD=build

PLAINTEXT_BODY='Hello, World!'
JSON_BODY='{"message":"Hello, World!"}'

# --- Описание серверов: сборка, команда запуска, что считать артефактом ---

build_khrip() {
	(cd .. && ./build.sh >/dev/null &&
		build/khc -o "bench/$BUILD/khrip/server" bench/khrip/server.kh)
}
build_go()         { (cd go && go build -o "../$BUILD/go/server" .); }
build_csharp()     { dotnet publish csharp -c Release -o "$BUILD/csharp" --nologo -v q >/dev/null; }
build_csharp_aot() { dotnet publish csharp -c Release -p:PublishAot=true -o "$BUILD/csharp-aot" --nologo -v q >/dev/null; }

cmd_khrip()      { echo "$BUILD/khrip/server"; }
cmd_go()         { echo "$BUILD/go/server"; }
cmd_csharp()     { echo "$BUILD/csharp/Api"; }
cmd_csharp_aot() { echo "$BUILD/csharp-aot/Api"; }

# Размер того, что нужно положить на сервер (без отладочных символов).
size_khrip()      { stat -c %s "$BUILD/khrip/server"; }
size_go()         { stat -c %s "$BUILD/go/server"; }
size_csharp()     { du -sb --exclude='*.pdb' "$BUILD/csharp" | cut -f1; }
size_csharp_aot() { stat -c %s "$BUILD/csharp-aot/Api"; }

title_khrip()      { echo "Khrip v0.5"; }
title_go()         { echo "Go 1.24 net/http"; }
title_csharp()     { echo "C# .NET 10 ASP.NET Core (JIT)*"; }
title_csharp_aot() { echo "C# .NET 10 ASP.NET Core (Native AOT)"; }

# --- Вспомогательные функции ---

# Переводит значение задержки wrk (850.00us, 1.23ms, 1.02s) в миллисекунды.
to_ms() {
	awk -v v="$1" 'BEGIN {
		n = v + 0
		if (v ~ /us$/) n /= 1000
		else if (v ~ /ms$/) n = n
		else if (v ~ /m$/) n *= 60000
		else if (v ~ /s$/) n *= 1000
		printf "%.2f", n
	}'
}

now_ns() { date +%s%N; }

wait_ready() {
	local i
	for i in $(seq 2000); do
		curl -s -o /dev/null "http://127.0.0.1:$PORT/plaintext" && return 0
		sleep 0.005
	done
	echo "сервер не поднялся" >&2
	return 1
}

check_body() {
	local path=$1 expected=$2 got
	got=$(curl -s "http://127.0.0.1:$PORT$path")
	if [[ "$got" != "$expected" ]]; then
		echo "неверный ответ на $path: '$got' (ожидалось '$expected')" >&2
		return 1
	fi
}

wrk_run() {
	taskset -c "$CLIENT_CPUS" wrk -t"$THREADS" -c"$CONNECTIONS" -d"$1" --latency "http://127.0.0.1:$PORT$2"
}

# Один прогон → строка "rps p50 p99 errors".
measure() {
	local out rps p50 p99 errors
	out=$(wrk_run "$DURATION" "$1")
	rps=$(awk '/^Requests\/sec:/ {printf "%.0f", $2}' <<<"$out")
	p50=$(to_ms "$(awk '$1 == "50%" {print $2}' <<<"$out")")
	p99=$(to_ms "$(awk '$1 == "99%" {print $2}' <<<"$out")")
	errors=$(awk '/Non-2xx|Socket errors/ {e = 1} END {print e ? "да" : "нет"}' <<<"$out")
	echo "$rps $p50 $p99 $errors"
}

# Медиана по RPS из RUNS прогонов.
median_of_runs() {
	local path=$1 i
	for i in $(seq "$RUNS"); do measure "$path"; done | sort -n -k1 | awk -v n="$RUNS" 'NR == int((n + 1) / 2)'
}

bench_server() {
	local name=$1 fn=${1//-/_} pid start ready startup_ms rss_kb size
	echo "== $(title_$fn)" >&2
	build_$fn

	start=$(now_ns)
	PORT=$PORT taskset -c "$SERVER_CPUS" "$(cmd_$fn)" >/dev/null 2>&1 &
	pid=$!
	wait_ready
	ready=$(now_ns)
	startup_ms=$(( (ready - start) / 1000000 ))

	check_body /plaintext "$PLAINTEXT_BODY"
	check_body /json "$JSON_BODY"

	wrk_run "$WARMUP" /plaintext >/dev/null
	wrk_run "$WARMUP" /json >/dev/null

	local plain json
	plain=$(median_of_runs /plaintext)
	json=$(median_of_runs /json)

	rss_kb=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status")
	kill "$pid"
	wait "$pid" 2>/dev/null || true

	size=$(size_$fn)
	read -r p_rps p_p50 p_p99 p_err <<<"$plain"
	read -r j_rps j_p50 j_p99 j_err <<<"$json"
	printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
		"$(title_$fn)" "$p_rps" "$p_p50" "$p_p99" "$j_rps" "$j_p50" "$j_p99" \
		"$(awk -v k="$rss_kb" 'BEGIN {printf "%.1f", k / 1024}')" "$(awk -v b="$size" 'BEGIN {printf "%.2f", b / 1048576}')" "$startup_ms"
	if [[ "$p_err" == "да" || "$j_err" == "да" ]]; then
		echo "  внимание: у $(title_$fn) были ошибки сокетов или не-2xx ответы" >&2
	fi
}

servers=("$@")
[[ ${#servers[@]} -eq 0 ]] && servers=(khrip go csharp csharp-aot)

mkdir -p "$BUILD/khrip" results
result="results/$(date +%Y-%m-%d)${LABEL:+-$LABEL}.md"
{
	echo "# Замеры $(date '+%Y-%m-%d %H:%M')"
	echo
	echo "Машина: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs), $(nproc) ядра, $(uname -sr)."
	echo "Сервер на ядрах $SERVER_CPUS, wrk на ядрах $CLIENT_CPUS: $THREADS потока, $CONNECTIONS соединений,"
	echo "прогрев $WARMUP, затем прогоны $RUNS × $DURATION; в таблице прогон с медианным RPS."
	echo
	echo "| Сервер | plaintext RPS | p50, мс | p99, мс | json RPS | p50, мс | p99, мс | Пик памяти, МБ | Размер, МБ | Старт, мс |"
	echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
	for s in "${servers[@]}"; do bench_server "$s"; done
	echo
	echo "\\* Для JIT-версии размер указан без среды .NET, которую нужно установить отдельно."
	echo "Старт: от запуска процесса до первого успешного HTTP-ответа (опрос curl, точность ~5–10 мс)."
} | tee "$result"
echo "Результат сохранён в bench/$result" >&2
