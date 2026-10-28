#!/usr/bin/env bash
# cg.sh <server.kh> <сценарий> <out> <lua>[:сек] ... — инструкции на запрос по
# веткам (callgrind, THREADS=1)
#
# Сервер собирается из server.kh (KHC — компилятор, по умолчанию build/khc
# этой копии; KHRIP_LIB — библиотека), получает таблицу символов (addsyms.py) и
# идёт под callgrind с --dump-instr=yes. После заполнения (load/seed.py) — по
# очереди каждая нагрузка: lua — сценарий wrk из load/ этой папки или
# eval/load, сек — длительность (по умолчанию 15). Нагрузка с префиксом «-»
# (например -book_post:60) — подготовка: её счётчики выбрасываются. Перед
# каждой измеряемой нагрузкой счётчики обнуляются, после — сбрасываются в
# <out>/cg.<n>.<lua>; число запросов — в <out>/reqs.tsv (lua, запросов по
# __dispatch, запросов по wrk, инструкций на запрос). Знаменатель — вызовы
# __dispatch в дампе: перед обнулением и перед дампом скрипт ждёт, пока сервер
# закончит начатые запросы. Фаза fill:N — bookings до N броней
# (fill_bookings.py). INSTR_OFF=1 — подготовка без инструментирования
# (valgrind --instr-atstart=no), оно включается перед первой измеряемой фазой.
# CG_FLAGS — ещё флаги callgrind (например --cache-sim=yes).
set -uo pipefail
here=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2/bench/results/2026-10-28-speed-baseline-data
root=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
src=$1; sc=$2; out=$3; shift 3
KHC=${KHC:-$root/build/khc}
port=${PORT_CG:-21580}
mkdir -p "$out"
"$KHC" --sizes -o "$out/server.raw" "$src" >"$out/sizes.txt" || exit 1
python3 "$here/addsyms.py" "$out/server.raw" "$out/sizes.txt" "$out/server" || exit 1
rm -f "$out"/cg.* "$out/reqs.tsv"
instr_flag=(${CG_FLAGS:-})
[[ ${INSTR_OFF:-0} == 1 ]] && instr_flag+=(--instr-atstart=no)
PORT=$port THREADS=1 valgrind --tool=callgrind "${instr_flag[@]}" --dump-instr=yes --compress-strings=no --compress-pos=no --callgrind-out-file="$out/cg.%p" \
	"$out/server" 2>"$out/valgrind.log" &
vp=$!
trap 'kill $vp 2>/dev/null; wait $vp 2>/dev/null' EXIT
for _ in $(seq 600); do
	curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && break
	sleep 0.1
done
env_line=$(cd "$root/eval" && SEED_PORT=$port python3 load/seed.py seed "$sc") || { echo "seed failed" >&2; exit 1; }; [[ -n "$env_line" ]] && export $env_line
wrk_run() { # lua secs
	local lua=$1 secs=$2 path
	path=$here/load/$lua.lua
	[[ -f $path ]] || path=$root/eval/load/$lua.lua
	LOAD_DIR=$root/eval/load WINDOW_SECONDS=1 taskset -c 2,3 wrk -t2 -c64 -d"${secs}s" -s "$path" "http://127.0.0.1:$port" 2>&1
}
# дождаться, пока сервер закончит начатые запросы (процессор не растёт 0,6 с)
wait_idle() {
	local a b quiet=0
	a=$(awk '{print $14 + $15}' /proc/$vp/stat)
	while ((quiet < 2)); do
		sleep 0.3
		b=$(awk '{print $14 + $15}' /proc/$vp/stat)
		if ((b - a <= 1)); then quiet=$((quiet + 1)); else quiet=0; fi
		a=$b
	done
}
# запросов в дампе: вызовы __dispatch
dispatched() { awk '/^cfn=/ {f = substr($0, 5)} /^calls=/ && f == "__dispatch" {split(substr($0, 7), a, " "); n += a[1]} END {print n + 0}' "$1"; }
n=0
for spec in "$@"; do
	lua=${spec%%:*}
	secs=15
	[[ $spec == *:* ]] && secs=${spec#*:}
	if [[ $lua == fill ]]; then
		echo "fill: $(python3 "$here/fill_bookings.py" "$port" "$secs")" >&2
		wait_idle
		continue
	fi
	if [[ $lua == -* ]]; then
		wrk_run "${lua#-}" "$secs" | awk '/requests in/ {print "prep '"${lua#-}"': " $1 " requests"}' >&2
		wait_idle
		continue
	fi
	[[ ${INSTR_OFF:-0} == 1 && $n == 0 ]] && callgrind_control -i on "$vp" >/dev/null 2>&1
	callgrind_control -z "$vp" >/dev/null 2>&1
	o=$(wrk_run "$lua" "$secs")
	wrk_reqs=$(awk '/requests in/ {print $1}' <<<"$o")
	wait_idle
	callgrind_control -d "$vp" >/dev/null 2>&1
	n=$((n + 1))
	sleep 0.5
	f=$(ls -t "$out"/cg."$vp".* 2>/dev/null | grep -v '\.[a-z_]*$' | head -1)
	[[ -n $f ]] && mv "$f" "$out/cg.$n.$lua"
	ir=$(grep -h '^totals:\|^summary:' "$out/cg.$n.$lua" | head -1 | awk '{print $2}')
	reqs=$(dispatched "$out/cg.$n.$lua")
	printf '%s\t%s\t%s\t%s\n' "$lua" "$reqs" "$wrk_reqs" "$((ir / reqs))" | tee -a "$out/reqs.tsv"
done
kill $vp 2>/dev/null
wait $vp 2>/dev/null
trap - EXIT
rm -f "$out/cg.$vp"
