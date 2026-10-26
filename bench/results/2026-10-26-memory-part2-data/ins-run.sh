#!/usr/bin/env bash
# run.sh <binary> <str|int> <total> [batch]: sum of thread CPU of the inserting requests, µs per insert
b=$1; kind=$2; total=$3; batch=${4:-65536}
port=20977
PORT=$port THREADS=1 KHRIP_GC=${GCV:-50} taskset -c 0 $b 2>/dev/null &
P=$!
for _ in $(seq 300); do curl -s -o /dev/null -X POST http://127.0.0.1:$port/$kind/0/0 && break; sleep 0.02; done
n=0; cpu=0
while ((n < total)); do
  read -r len c d < <(curl -s -X POST http://127.0.0.1:$port/$kind/$n/$((n + batch)))
  cpu=$((cpu + c)); n=$((n + batch))
done
utime=$(awk '{print ($14 + $15) * 10000}' /proc/$P/stat)
kill $P; wait $P 2>/dev/null
echo "$(basename $b) $kind $total: request cpu ${cpu} us, $(awk -v c=$cpu -v n=$total 'BEGIN{printf "%.3f", c/n}') us/insert; process cpu $utime us"
