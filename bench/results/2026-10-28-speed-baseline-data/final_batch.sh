#!/usr/bin/env bash
# Итоговая партия: варианты в замкнутом цикле (ab4), разрыв при одинаковой
# частоте (gap.sh rate: eval/perf.sh RATE_MODE=1), варианты при одинаковой
# частоте (ab.sh с RATE).
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/sp1
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed1
D=$R/bench/results/2026-10-28-speed-baseline-data
V=$S/var
Q=$R/bench/tools/quiet.sh
export TMPDIR=$S
cd $R || exit 1
echo "ab4 catalog $(date +%T)"
$Q $D/ab.sh catalog 4 $D/ab4_catalog.tsv $V/c0_base $V/c0_catfix2 $V/c7_cil_libx2 $V/c7_catfix2_libx csharp >$D/ab4_catalog.log 2>&1
echo "ab4 bookings $(date +%T)"
$Q $D/ab.sh bookings 4 $D/ab4_bookings.tsv $V/b0_base $V/b1_loop $V/b1_liby csharp >$D/ab4_bookings.log 2>&1
dotnet build-server shutdown >/dev/null 2>&1
echo "rate gap $(date +%T)"
$D/gap.sh rate 3 catalog=2800 catalog=4000 bookings=3000 bookings=5000 >$D/rate.log 2>&1
dotnet build-server shutdown >/dev/null 2>&1
echo "rate variants $(date +%T)"
for rate in 2800 4000; do
	RATE=$rate $Q $D/ab.sh catalog 2 $D/abrate_catalog.tsv $V/c7_catfix2_libx >>$D/abrate.log 2>&1
done
for rate in 3000 5000; do
	RATE=$rate $Q $D/ab.sh bookings 2 $D/abrate_bookings.tsv $V/b1_loop >>$D/abrate.log 2>&1
done
echo "final-batch-finished $(date +%T)"
