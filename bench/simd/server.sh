#!/usr/bin/env bash
# Сервер на одном ядре, запросы с заголовками как у браузера (~700 байт):
# RPS при KHRIP_SIMD=0 (побайтно) и 2 (AVX2).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p bench/build
build/khc -o bench/build/simd-server bench/khrip/server.kh
port=18500
H=(
	-H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
	-H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
	-H "Accept-Language: en-US,en;q=0.9,ru;q=0.8"
	-H "Accept-Encoding: gzip, deflate, br, zstd"
	-H "Referer: https://www.example.com/articles/41?utm_source=newsletter&utm_medium=email"
	-H "Cookie: session=6f1c2a9e8b7d4c3f2e1a0b9c8d7e6f5a4b3c2d1e; theme=dark; consent=analytics,ads; _ga=GA1.1.123456789.1700000000"
	-H "Sec-Fetch-Dest: document"
	-H "Sec-Fetch-Mode: navigate"
	-H "Cache-Control: max-age=0"
)
# Уровни чередуются, каждый прогон — отдельный запуск сервера; в таблице медиана.
ROUNDS=${ROUNDS:-5}
declare -A res
for round in $(seq "$ROUNDS"); do
	for lvl in 0 2; do
		KHRIP_SIMD=$lvl THREADS=1 PORT=$port taskset -c 0 bench/build/simd-server 2>/dev/null &
		pid=$!
		sleep 0.3
		for path in /plaintext /json; do
			taskset -c 2,3 wrk -t2 -c64 -d1s "${H[@]}" "http://127.0.0.1:$port$path" >/dev/null
			rps=$(taskset -c 2,3 wrk -t2 -c64 -d3s "${H[@]}" "http://127.0.0.1:$port$path" | awk '/^Requests\/sec:/ {printf "%.0f", $2}')
			res[$lvl$path]="${res[$lvl$path]:-} $rps"
		done
		kill $pid
		wait $pid 2>/dev/null || true
	done
done
median() { tr ' ' '\n' <<<"$1" | grep . | sort -n | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}'; }
echo "| Путь | plaintext RPS | json RPS |"
echo "|---|---:|---:|"
for lvl in 0 2; do
	name=$( [[ $lvl == 2 ]] && echo "AVX2" || echo "побайтно" )
	echo "| $name | $(median "${res[$lvl/plaintext]}") | $(median "${res[$lvl/json]}") |"
done
echo
echo "Медиана из $ROUNDS прогонов по 3 с; уровни чередуются."
