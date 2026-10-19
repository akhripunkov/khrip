#!/usr/bin/env bash
# Выигрыш от SIMD: тот же код рантайма на трёх путях (KHRIP_SIMD=0, 1, 2).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p bench/build
build/khc -o bench/build/simd bench/simd/simd.kh
echo "| Путь | Заголовки HTTP, нс | Запись JSON, нс | Чтение JSON, нс |"
echo "|---|---:|---:|---:|"
for lvl in 0 1 2; do
	best=""
	for r in 1 2 3; do
		line=$(KHRIP_SIMD=$lvl taskset -c 1 bench/build/simd)
		read -r got http enc dec rn jn _ <<<"$line"
		if [[ -z "$best" ]] || (( http + enc + dec < best_sum )); then
			best="$http $enc $dec"
			best_sum=$((http + enc + dec))
		fi
	done
	read -r http enc dec <<<"$best"
	name=$( [[ $got == 2 ]] && echo "AVX2" || ([[ $got == 1 ]] && echo "SSE2" || echo "побайтно") )
	echo "| $name | $http | $enc | $dec |"
done
echo
echo "Запрос: $rn байт заголовков; JSON: $jn байт. Лучший из 3 прогонов, одно ядро."
