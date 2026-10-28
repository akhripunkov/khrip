#!/usr/bin/env bash
# same_run.sh <сценарий> <сервер A> <сервер B> — ответы одинаковы (same.py)
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
sc=$1; a=$2; b=$3
PORT=21601 THREADS=2 "$a" 2>/dev/null & pa=$!
PORT=21602 THREADS=2 "$b" 2>/dev/null & pb=$!
trap 'kill $pa $pb 2>/dev/null; wait 2>/dev/null' EXIT
for p in 21601 21602; do for _ in $(seq 300); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:$p/ && break; sleep 0.05; done; done
for p in 21601 21602; do (cd $S/eval && SEED_PORT=$p python3 load/seed.py seed $sc >/dev/null) || echo "seed failed $p"; done
python3 $S/bench/results/2026-10-28-speed-baseline-data/variants/same.py 21601 21602 $sc
