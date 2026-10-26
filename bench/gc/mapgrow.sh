#!/usr/bin/env bash
# Самая долгая вставка в словарь store по мере роста до 2^23 записей (этап
# памяти, часть 2): bench/gc/mapgrow.kh, запросы по BATCH вставок.
#
#   bench/gc/mapgrow.sh <int|str> [записей]     (по умолчанию 8388608)
#
# Окружение: KHC (компилятор, по умолчанию build/khc этого репозитория), BATCH
# (65536), GC (значение KHRIP_GC, по умолчанию как в программе), PORT_MG
# (8080), CPUS (ядра сервера, 0,1). Печатает по строке на каждый запрос, где
# самая долгая вставка дольше 1 мс, и итог: самая долгая вставка, вставок
# дольше 1 мс и самая долгая вставка каждого вида — начало роста, шаг роста,
# без роста — по часам и по времени процессора потока.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kind=${1:?int или str}
total=${2:-8388608}
KHC=${KHC:-$root/build/khc}
BATCH=${BATCH:-65536}
port=${PORT_MG:-8080}
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
"$KHC" -o "$tmp/server" "$here/mapgrow.kh" || exit 1
envs=(PORT=$port THREADS=1)
[[ -n ${GC:-} ]] && envs+=(KHRIP_GC=$GC)
env "${envs[@]}" taskset -c "${CPUS:-0,1}" "$tmp/server" 2>"$tmp/log" &
pid=$!
for _ in $(seq 500); do
	curl -s -o /dev/null "http://127.0.0.1:$port/len" && break
	sleep 0.01
done
worst=0
worst_at=0
slow=0
ms_start=0
ms_step=0
ms_none=0
cpu_start=0
cpu_step=0
cpu_none=0
cslow=0
nstep=0
sstep=0
nnone=0
snone=0
n=0
while ((n < total)); do
	read -r n w at s ms a b c ca cb cc cs ns ss nn sn < <(curl -s -X POST "http://127.0.0.1:$port/$kind/$BATCH")
	[[ -n ${n:-} ]] || { echo "сервер не ответил" >&2; cat "$tmp/log" >&2; exit 1; }
	((w > 1000)) && echo "$kind: до $n записей: самая долгая вставка $w мкс (на записи $at; начало роста $a, шаг $b, без роста $c), дольше 1 мс — $s, запрос $ms мс"
	((w > worst)) && { worst=$w; worst_at=$at; }
	((a > ms_start)) && ms_start=$a
	((b > ms_step)) && ms_step=$b
	((c > ms_none)) && ms_none=$c
	((ca > cpu_start)) && cpu_start=$ca
	((cb > cpu_step)) && cpu_step=$cb
	((cc > cpu_none)) && cpu_none=$cc
	slow=$((slow + s))
	cslow=$((cslow + cs))
	nstep=$((nstep + ns))
	sstep=$((sstep + ss))
	nnone=$((nnone + nn))
	snone=$((snone + sn))
done
echo "$kind: $n записей, самая долгая вставка $worst мкс (на записи $worst_at), вставок дольше 1 мс — $slow; самая долгая: начало роста $ms_start мкс, шаг роста $ms_step мкс, без роста $ms_none мкс; по процессору — $cpu_start, $cpu_step и $cpu_none мкс, дольше 1 мс — $cslow; дольше 1 мс по часам: шагов роста $sstep из $nstep, вставок без роста $snone из $nnone; RSS $(awk '/^VmRSS:/ {print $2}' /proc/$pid/status) КБ"
