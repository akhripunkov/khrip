#!/usr/bin/env bash
# Удаление 90% store против Go (этап памяти, часть 1): bench/gc/delete.kh и
# его перенос bench/gc/delete_go/ — 200 тысяч товаров (20 запросов по 10 000),
# затем удаление 90% старых подряд (oldest) или вразнобой (random), затем
# простой. RSS: после заполнения, сразу после удаления, через IDLE (15) с и
# через IDLE_LONG (60) с простоя; живое — у Khrip по последней сборке, у Go —
# HeapAlloc после принудительной сборки (GET /stats вызывает runtime.GC, поэтому
# его просят только после простоя). Go без выделений сам не собирает (сборка
# по таймеру — раз в 2 минуты), поэтому у него ещё два значения: через IDLE с
# после принудительной сборки (фоновый возврат памяти) и после
# debug.FreeOSMemory — нижняя граница; у Khrip оба равны RSS после простоя
# (сборка простоя уже вернула все свободные страницы).
#
#   bench/gc/delete_cmp.sh            → строки TSV в stdout и в OUT (bench/gc/out/delete_cmp.tsv)
#
# Сервер на ядрах SERVER_CPUS (0,1), порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SERVER_CPUS=${SERVER_CPUS:-0,1}
IDLE=${IDLE:-15}
IDLE_LONG=${IDLE_LONG:-60}
OUT=${OUT:-$here/out/delete_cmp.tsv}
port=8080
mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status"; }
up() {
	for _ in $(seq 500); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/stats" && return 0
		sleep 0.01
	done
	return 1
}

"$root/build/khc" -o "$tmp/delete-khrip" "$here/delete.kh" || exit 1
(cd "$here/delete_go" && go build -o "$tmp/delete-go" .) || exit 1

[[ -f $OUT ]] || printf 'lang\thow\tleft\tfull_kb\tafter_delete_kb\tidle_%ss_kb\tidle_%ss_kb\tafter_gc_%ss_kb\tfloor_kb\tlive_kb\theap_kb\tcycles\n' "$IDLE" "$IDLE_LONG" "$IDLE" >"$OUT"
for lang in khrip go; do
	for how in oldest random; do
		PORT=$port taskset -c "$SERVER_CPUS" "$tmp/delete-$lang" 2>/dev/null &
		pid=$!
		up || exit 1
		for _ in $(seq 20); do
			curl -s -o /dev/null -X POST "http://127.0.0.1:$port/fill/10000"
		done
		full=$(rss)
		curl -s -o /dev/null -X POST "http://127.0.0.1:$port/delete/$how/200000"
		after=$(rss)
		sleep "$IDLE"
		idle=$(rss)
		sleep $((IDLE_LONG - IDLE))
		idle_long=$(rss)
		read -r left live heap cycles < <(curl -s "http://127.0.0.1:$port/stats")
		after_gc=$idle_long
		floor=$idle_long
		if [[ $lang == go ]]; then
			sleep "$IDLE"
			after_gc=$(rss)
			curl -s -o /dev/null -X POST "http://127.0.0.1:$port/free"
			sleep 1
			floor=$(rss)
		fi
		kill "$pid"
		wait "$pid" 2>/dev/null
		pid=
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lang" "$how" "$left" "$full" "$after" "$idle" "$idle_long" \
			"$after_gc" "$floor" $((live / 1024)) $((heap / 1024)) "$cycles" | tee -a "$OUT"
	done
done
