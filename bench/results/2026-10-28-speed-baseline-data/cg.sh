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
# <out>/cg.<n>.<lua>; число запросов — в <out>/reqs.tsv (lua, запросов,
# инструкций на запрос).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
src=$1; sc=$2; out=$3; shift 3
KHC=${KHC:-$root/build/khc}
port=${PORT_CG:-21580}
mkdir -p "$out"
"$KHC" --sizes -o "$out/server.raw" "$src" >"$out/sizes.txt" || exit 1
python3 "$here/addsyms.py" "$out/server.raw" "$out/sizes.txt" "$out/server" || exit 1
rm -f "$out"/cg.* "$out/reqs.tsv"
PORT=$port THREADS=1 valgrind --tool=callgrind --dump-instr=yes --callgrind-out-file="$out/cg.%p" \
	"$out/server" 2>"$out/valgrind.log" &
vp=$!
trap 'kill $vp 2>/dev/null; wait $vp 2>/dev/null' EXIT
for _ in $(seq 600); do
	curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && break
	sleep 0.1
done
(cd "$root/eval" && SEED_PORT=$port python3 load/seed.py seed "$sc" >/dev/null) || { echo "seed failed" >&2; exit 1; }
wrk_run() { # lua secs
	local lua=$1 secs=$2 path
	path=$here/load/$lua.lua
	[[ -f $path ]] || path=$root/eval/load/$lua.lua
	LOAD_DIR=$root/eval/load WINDOW_SECONDS=1 taskset -c 2,3 wrk -t2 -c64 -d"${secs}s" -s "$path" "http://127.0.0.1:$port" 2>&1
}
n=0
for spec in "$@"; do
	lua=${spec%%:*}
	secs=15
	[[ $spec == *:* ]] && secs=${spec#*:}
	if [[ $lua == -* ]]; then
		wrk_run "${lua#-}" "$secs" | awk '/requests in/ {print "prep '"${lua#-}"': " $1 " requests"}' >&2
		continue
	fi
	callgrind_control -z "$vp" >/dev/null 2>&1
	o=$(wrk_run "$lua" "$secs")
	reqs=$(awk '/requests in/ {print $1}' <<<"$o")
	callgrind_control -d "$vp" >/dev/null 2>&1
	n=$((n + 1))
	sleep 0.5
	f=$(ls -t "$out"/cg."$vp".* 2>/dev/null | grep -v '\.[a-z_]*$' | head -1)
	[[ -n $f ]] && mv "$f" "$out/cg.$n.$lua"
	ir=$(grep -h '^totals:\|^summary:' "$out/cg.$n.$lua" | head -1 | awk '{print $2}')
	printf '%s\t%s\t%s\n' "$lua" "$reqs" "$((ir / reqs))" | tee -a "$out/reqs.tsv"
done
kill $vp 2>/dev/null
wait $vp 2>/dev/null
trap - EXIT
rm -f "$out/cg.$vp"
