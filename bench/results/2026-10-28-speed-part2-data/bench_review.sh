#!/usr/bin/env bash
# Один круг после правок ревью: catalog и bookings — основа, итог до ревью (i4),
# после ревью (rf) и C#, замкнутый цикл, под quiet.sh.
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2
AB=$R/bench/results/2026-10-28-speed-baseline-data/ab.sh
Q=$R/bench/tools/quiet.sh
rounds=${ROUNDS:-1}
if pgrep -f 'tests/run|wrk|perf.sh|suite.sh' >/dev/null; then echo "идёт другой замер или тесты" >&2; exit 2; fi
cd $S/bin
CS_DIR=$S/cs/catalog $Q $AB catalog $rounds $S/ab/review_catalog.tsv $S/bin/catalog_base $S/bin/catalog_i4 $S/bin/catalog_rf csharp
CS_DIR=$S/cs/bookings $Q $AB bookings $rounds $S/ab/review_bookings.tsv $S/bin/bookings_base $S/bin/bookings_i4 $S/bin/bookings_rf csharp
echo review-finished
