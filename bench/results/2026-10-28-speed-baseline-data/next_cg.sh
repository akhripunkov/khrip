#!/usr/bin/env bash
# Следующая партия callgrind (после ab3): сборки с новыми libx/liby, проверки и замеры.
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/sp1
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed1
D=$R/bench/results/2026-10-28-speed-baseline-data
K=$R/build/khc
E=$R/eval
V=$S/var
cd $V || exit 1
# сборки
KHRIP_LIB=$S/libx $K -o c7_catfix_libx c7_catfix.kh || exit 1
KHRIP_LIB=$S/liby $K -o b0_liby b0_base.kh || exit 1
KHRIP_LIB=$S/liby $K -o b1_liby b1_loop.kh || exit 1
KHRIP_LIB=$S/libx $K -o lt_new lt_new.kh || exit 1
./lt_new | cmp - lt_ref.out && echo "lt: IDENTICAL"
# ответы те же
PORT=21701 ./c0_base 2>/dev/null & P0=$!
sleep 0.3
(cd $E && SEED_PORT=21701 python3 load/seed.py seed catalog)
PORT=21702 ./c7_catfix_libx 2>/dev/null & P1=$!
sleep 0.3
(cd $E && SEED_PORT=21702 python3 load/seed.py seed catalog)
echo "c7_catfix_libx: $(python3 same.py 21701 21702 catalog | tail -1)"
kill $P0 $P1; wait $P0 $P1 2>/dev/null
for v in b0_liby b1_liby; do
	PORT=21701 ./b0_base 2>/dev/null & P0=$!
	PORT=21702 ./$v 2>/dev/null & P1=$!
	sleep 0.3
	(cd $E && SEED_PORT=21701 python3 load/seed.py seed bookings; SEED_PORT=21702 python3 load/seed.py seed bookings)
	echo "$v: $(python3 same.py 21701 21702 bookings | tail -1)"
	kill $P0 $P1; wait $P0 $P1 2>/dev/null
done
# callgrind
echo "== c0_base: наклон (6 с и 20 с одной ветки)"
$D/cg.sh $V/c0_base.kh catalog $V/cg_c0_slope -catalog:4 cat_a:6 cat_a:20 cat_d:6 cat_d:20 2>&1 | grep -v символов
echo "== c0_catfix"
$D/cg.sh $V/c0_catfix.kh catalog $V/cg_c0_catfix -catalog:4 cat_d:10 catalog:15 2>&1 | grep -v символов
echo "== c7_catfix_libx"
KHRIP_LIB=$S/libx $D/cg.sh $V/c7_catfix.kh catalog $V/cg_c7_catfix_libx -catalog:4 cat_a:12 cat_b:12 cat_d:10 catalog:15 2>&1 | grep -v символов
echo "== b0_liby"
KHRIP_LIB=$S/liby INSTR_OFF=1 $D/cg.sh $V/b0_base.kh bookings $V/cg_b0_liby fill:11000 book_get:12 book_post:12 2>&1 | grep -v символов
echo "== b1_liby"
KHRIP_LIB=$S/liby INSTR_OFF=1 $D/cg.sh $V/b1_loop.kh bookings $V/cg_b1_liby fill:11000 book_get:12 book_post:12 2>&1 | grep -v символов
echo next-cg-finished
