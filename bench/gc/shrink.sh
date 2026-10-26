#!/usr/bin/env bash
# Рост и сжатие store (docs/design/v0.13-store-gc.md §16): живое 32 МБ, затем
# 4 МБ; после простоя (10 с без выделений: сборка и вся свободная память —
# системе) RSS через 30 с не больше 1,5 · (живое + 1 МБ). Сервер
# tests/gc/server.kh (2000 товаров, список чисел /big).
#
#   bench/gc/shrink.sh [корень khc]   (по умолчанию этот репозиторий)
#
# Порт GATE_PORT (по умолчанию 8080).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kroot=${1:-$root}
port=${GATE_PORT:-8080}
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
KHRIP_GC_LOG=1 "$kroot/build/khc" -o "$tmp/srv" "$root/tests/gc/server.kh" || exit 1
rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status"; }
url=http://127.0.0.1:$port

PORT=$port THREADS=4 KHRIP_GC_LOG=1 "$tmp/srv" 2>"$tmp/log" &
pid=$!
for _ in $(seq 500); do
	curl -s -o /dev/null --max-time 1 "$url/count" && break
	sleep 0.01
done
curl -s -o /dev/null -X POST "$url/seed"
curl -s -o /dev/null -X POST "$url/big/4000000"
read -r _ _ live0 < <(curl -s "$url/gcstats")
r0=$(rss)
curl -s -o /dev/null -X POST "$url/big-drop"
curl -s -o /dev/null -X POST "$url/big/450000"
read -r _ _ live1 < <(curl -s "$url/gcstats")
r1=$(rss)
# простой: 10 тиков по секунде без выделений, затем 30 с
sleep 42
read -r cyc _ live2 < <(curl -s "$url/gcstats")
r2=$(rss)
kill "$pid"
wait "$pid" 2>/dev/null
pid=
limit=$(((live2 + 1048576) * 3 / 2 / 1024))
verdict=ok
((r2 > limit)) && verdict=FAIL
echo "grown: live $((live0 / 1024)) KB, RSS $r0 KB; shrunk: live $((live1 / 1024)) KB, RSS $r1 KB; 30 s after the idle release: live $((live2 / 1024)) KB, RSS $r2 KB ($cyc cycles); gate 1.5 x (live + 1 MB) = $limit KB: $verdict"
grep -c '^gc [0-9]* (idle)' "$tmp/log" | sed 's/^/idle cycles: /'
[[ $verdict == ok ]]
