#!/usr/bin/env bash
# perfrec.sh khrip|csharp <сценарий> <out> [lua] — время процессора по функциям
# (perf record -e cpu-clock: счётчиков процессора в этой виртуальной машине нет)
#
# Сервер — на ядрах 0,1 (как eval/perf.sh), wrk — на 2,3, 64 соединения:
# заполнение (load/seed.py), прогрев 3 с, затем wrk 12 с, и perf пишет 8 с
# с середины. Khrip — с таблицей символов (addsyms.py), C# — с
# DOTNET_PerfMapEnabled=1 и DOTNET_EnableWriteXorExecute=0 (код JIT — в
# анонимной памяти, perf читает имена из /tmp/perf-<pid>.map).
# Итог: <out>/perf.data, <out>/flat.txt (по функциям), <out>/dso.txt,
# <out>/wrk.txt, <out>/cpu_us.txt (процессор сервера на запрос за 12 с).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
lang=$1; sc=$2; out=$3; lua=${4:-$sc}
PERF=${PERF:-/usr/lib/linux-tools-6.8.0-147/perf}
task=$sc
[[ $sc == patch ]] && task=catalog
mkdir -p "$out"
path=$here/load/$lua.lua
[[ -f $path ]] || path=$root/eval/load/$lua.lua
case $lang in
khrip)
	"$root/build/khc" --sizes -o "$out/server.raw" "$root/eval/solutions/$task/khrip/main.kh" >"$out/sizes.txt" || exit 1
	python3 "$here/addsyms.py" "$out/server.raw" "$out/sizes.txt" "$out/server" || exit 1
	PORT=8080 taskset -c 0,1 "$out/server" 2>/dev/null &
	;;
csharp)
	[[ -d $out/cs ]] || dotnet publish "$root/eval/solutions/$task/csharp" -c Release -o "$out/cs" --nologo -v q >/dev/null || exit 1
	ASPNETCORE_URLS=http://127.0.0.1:8080 Logging__LogLevel__Default=Warning DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 \
		taskset -c 0,1 dotnet "$out/cs/App.dll" >/dev/null &
	;;
esac
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null' EXIT
for _ in $(seq 3000); do
	curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/ && break
	sleep 0.01
done
(cd "$root/eval" && python3 load/seed.py seed "$sc" >/dev/null) || exit 1
w() { LOAD_DIR=$root/eval/load WINDOW_SECONDS=1 taskset -c 2,3 wrk -t2 -c64 --latency -d"$1" -s "$path" http://127.0.0.1:8080; }
w 3s >/dev/null 2>&1
c0=$(awk '{print $14 + $15}' /proc/$pid/stat)
w 12s >"$out/wrk.txt" 2>&1 &
wp=$!
sleep 2
"$PERF" record -q -e cpu-clock -F 4999 -g -p "$pid" -o "$out/perf.data" -- sleep 8 2>/dev/null
wait $wp
c1=$(awk '{print $14 + $15}' /proc/$pid/stat)
reqs=$(awk '/requests in/ {print $1}' "$out/wrk.txt")
# процессор сервера на запрос за все 12 с (с perf на 8 из них), мкс
awk -v c=$((c1 - c0)) -v n="$reqs" 'BEGIN {printf "%.1f\n", c * 10000 / n}' >"$out/cpu_us.txt"
"$PERF" report -i "$out/perf.data" --no-children --sort sym --stdio -g none 2>/dev/null | grep '%' >"$out/flat.txt"
"$PERF" report -i "$out/perf.data" --no-children --sort dso --stdio -g none 2>/dev/null | grep '%' >"$out/dso.txt"
echo "$(grep -E 'Requests/sec' "$out/wrk.txt"), CPU $(cat "$out/cpu_us.txt") us/req"
