#!/usr/bin/env bash
# Review re-measurements, part A (quick ones). tree0 = a6176a0, tree5 = e7fd905 (before the review), tree6 = review fixes.
set -u
D=$SCRATCH/m2
R=$D/rev
W=$D/../par/mem2
Q=$W/bench/tools/quiet.sh
P=$R/progress
step() { echo "== $(date +%T) $*" >> $P; }
khc() { local t=$1; shift; KHRIP_LIB=$D/$t/lib $D/$t/build/khc "$@"; }
cd $R

# 1. copy-then-grow (reviewer's copygrow2.kh, n = 1.1M)
step copygrow
for t in tree0 tree5 tree6; do
  echo "$t: $(khc $t test copygrow2.kh 2>&1 | grep -E 'after' | tr '\n' ' ')" >> copygrow.txt
done

# 2. hold: 400 inner maps growing at once (server, KHRIP_GC_LOG build)
step hold
for t in tree5 tree6; do
  KHRIP_GC_LOG=1 khc $t -o hold_$t hold.kh
  BIN=$R/hold_$t bash $R/hold.sh > hold_$t.txt 2>&1
  echo "$t: $(khc $t test hold_test.kh 2>&1 | grep -E 'before|growing|after' | tr '\n' ' ')" >> hold_test.txt
done

# 3. buffers: dead clients and response buffers after a burst (pool.kh, THREADS=1)
step burst
for t in tree5 tree6; do
  khc $t -o pool_$t pool.kh
  for size in 100000 900000; do
    PORT=20612 THREADS=1 taskset -c 0 ./pool_$t >/dev/null 2>&1 &
    p=$!
    for i in $(seq 100); do curl -s -o /dev/null http://127.0.0.1:20612/echo/x && break; sleep 0.05; done
    echo "$t size $size: $(taskset -c 2,3 python3 burst.py 20612 250 $size $p | tr '\n' ' ')" >> burst.txt
    kill $p; wait $p 2>/dev/null
  done
done

# 4. large requests: µs per request by arena size (1 connection, closed loop)
step bigreq
for t in tree0 tree5 tree6; do khc $t -o big_$t big.kh; done
$Q bash -c '
for r in 1 2 3; do
  for v in tree0 tree5 tree6; do
    PORT=20620 THREADS=1 taskset -c 0 ./big_$v >/dev/null 2>&1 &
    p=$!
    for i in $(seq 100); do curl -s -o /dev/null http://127.0.0.1:20620/big/1 && break; sleep 0.05; done
    line="r$r $v"
    for kb in 16 64 256 1024 4096; do
      taskset -c 2 wrk -t1 -c1 -d1s http://127.0.0.1:20620/big/$kb >/dev/null 2>&1
      rps=$(taskset -c 2 wrk -t1 -c1 -d3s http://127.0.0.1:20620/big/$kb 2>&1 | awk "/^Requests\/sec/ {print \$2}")
      line="$line $kb:$(awk -v r=$rps "BEGIN {printf \"%.1f\", 1e6 / r}")"
    done
    echo "$line rssKB:$(awk "/VmRSS/ {print \$2}" /proc/$p/status)"
    kill $p; wait $p 2>/dev/null
  done
done' >> bigreq.txt 2>&1
step done partA
