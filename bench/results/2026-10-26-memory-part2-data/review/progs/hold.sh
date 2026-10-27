#!/usr/bin/env bash
cd $SCRATCH/m2/rev
BIN=${BIN:-./hold}
KHRIP_GC_LOG=1 PORT=20630 THREADS=2 $BIN 2> hold_srv.log &
p=$!
for i in $(seq 100); do curl -s -o /dev/null http://127.0.0.1:20630/x && break; sleep 0.05; done
curl -s -X POST http://127.0.0.1:20630/setup/400/1983; echo
sleep 1
grep -c '^gc ' hold_srv.log
curl -s -X POST http://127.0.0.1:20630/step/400/1983 >/dev/null
curl -s -X POST http://127.0.0.1:20630/step/400/1984 >/dev/null
for i in $(seq 40); do curl -s -X POST http://127.0.0.1:20630/garbage/20000 >/dev/null; done
for k in $(seq 1985 2030); do curl -s -X POST http://127.0.0.1:20630/step/400/$k > /dev/null; done
sleep 1
kill $p; wait $p 2>/dev/null
grep '^gc ' hold_srv.log | sed 's/, pins.*arenas [^)]*),//' | cut -c1-260 | tail -12
