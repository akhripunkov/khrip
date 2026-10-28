#!/usr/bin/env bash
# Партия callgrind 2: /categories без записи в поле (catfix2), итоговый вариант,
# модель кеша callgrind для bookings GET и catalog ветки 1.
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/sp1
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed1
D=$R/bench/results/2026-10-28-speed-baseline-data
V=$S/var
echo "== c0_catfix2"
$D/cg.sh $V/c0_catfix2.kh catalog $V/cg_c0_catfix2 -catalog:4 cat_d:10 catalog:15 2>&1 | grep -v символов
echo "== c7_catfix2_libx"
KHRIP_LIB=$S/libx $D/cg.sh $V/c7_catfix2.kh catalog $V/cg_c7_catfix2_libx -catalog:4 cat_a:12 cat_b:12 cat_d:10 catalog:15 2>&1 | grep -v символов
echo "== c7_cil_libx (новая libx: пустая подстрока сразу)"
KHRIP_LIB=$S/libx $D/cg.sh $V/c7_cil.kh catalog $V/cg_c7_cil_libx2 -catalog:4 cat_a:12 catalog:15 2>&1 | grep -v символов
echo "== c3_loop_libx и c8 (новая libx)"
KHRIP_LIB=$S/libx $D/cg.sh $V/c8_cil_chain.kh catalog $V/cg_c8_libx2 -catalog:4 cat_a:12 catalog:15 2>&1 | grep -v символов
echo "== кеш: c0_base ветка 1"
CG_FLAGS=--cache-sim=yes $D/cg.sh $V/c0_base.kh catalog $V/cgc_c0 -catalog:4 cat_a:12 2>&1 | grep -v символов
echo "== кеш: b0 GET при 11 000"
CG_FLAGS=--cache-sim=yes INSTR_OFF=1 $D/cg.sh $V/b0_base.kh bookings $V/cgc_b0 fill:11000 book_get:12 2>&1 | grep -v символов
echo "== кеш: b1 GET при 11 000"
CG_FLAGS=--cache-sim=yes INSTR_OFF=1 $D/cg.sh $V/b1_loop.kh bookings $V/cgc_b1 fill:11000 book_get:12 2>&1 | grep -v символов
echo next-cg2-finished
