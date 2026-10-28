#!/usr/bin/env bash
# Замкнутый цикл: все стадии и C# по кругу (ab.sh из данных части 1), под quiet.sh.
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
AB=$R/bench/results/2026-10-28-speed-baseline-data/ab.sh
Q=$R/bench/tools/quiet.sh
rounds=${ROUNDS:-5}
if pgrep -f 'tests/run|wrk|perf.sh|suite.sh' >/dev/null; then echo "идёт другой замер или тесты" >&2; exit 2; fi
cd $S/bin
CS_DIR=$S/cs/catalog $Q $AB catalog $rounds $S/ab/closed_catalog.tsv $S/bin/catalog_base $S/bin/catalog_i1 $S/bin/catalog_i2 $S/bin/catalog_i3 $S/bin/catalog_i4 csharp
CS_DIR=$S/cs/bookings $Q $AB bookings $rounds $S/ab/closed_bookings.tsv $S/bin/bookings_base $S/bin/bookings_i1 $S/bin/bookings_i3 csharp
echo closed-finished
