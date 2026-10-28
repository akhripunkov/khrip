#!/usr/bin/env bash
# callgrind по веткам для стадий: cg_batch.sh <стадия>... (base tree1 tree2 tree3 tree4)
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
D=$R/bench/results/2026-10-28-speed-baseline-data
for st in "$@"; do
	tree=$S/$st
	[[ $st == base ]] && tree=$S/basetree
	echo "== $st catalog $(date +%T)"
	KHC=$tree/build/khc $D/cg.sh $R/eval/solutions/catalog/khrip/main.kh catalog $S/cg/$st-catalog -catalog:4 cat_a:12 cat_b:12 cat_c:8 cat_d:10 catalog:15 2>&1 | grep -v символов
	echo "== $st bookings $(date +%T)"
	KHC=$tree/build/khc INSTR_OFF=1 $D/cg.sh $R/eval/solutions/bookings/khrip/main.kh bookings $S/cg/$st-bookings fill:8500 book_get:12 book_post:12 bookings:12 fill:11000 book_get:12 book_post:12 bookings:12 2>&1 | grep -v символов
done
echo cg-batch-finished
