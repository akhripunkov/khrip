#!/usr/bin/env bash
# Постоянная частота (wrk2, прогрев и замер по 60 с): итог части 2 против C# в
# одной партии; порядок чередуется по кругам. bench_rate.sh [кругов]
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
AB=$R/bench/results/2026-10-28-speed-baseline-data/ab.sh
Q=$R/bench/tools/quiet.sh
rounds=${1:-3}
if pgrep -f 'tests/run|wrk|perf.sh|suite.sh|valgrind' >/dev/null; then echo "идёт другой замер или тесты" >&2; exit 2; fi
cd $S/bin
for r in $(seq "$rounds"); do
	for pair in catalog=2800 catalog=4000 catalog=5000 bookings=3000 bookings=5000; do
		sc=${pair%%=*}; rate=${pair#*=}
		if ((r % 2)); then vs=("$S/bin/${sc}_i4" csharp); else vs=(csharp "$S/bin/${sc}_i4"); fi
		echo "## round $r $sc@$rate $(date +%T)" >&2
		RATE=$rate CS_DIR=$S/cs/$sc $Q $AB "$sc" 1 "$S/ab/rate_$sc.tsv" "${vs[@]}" | sed "s/^1\t/$r\t/"
	done
done
echo rate-finished
