#!/usr/bin/env bash
# 13 сценариев eval/perf.sh (замкнутый цикл, только Khrip): основа bb686f1 и
# итог части 2 по кругу, порядок чередуется. bench_regr.sh [кругов] [сценарии...]
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2
rounds=${1:-4}
shift || true
if pgrep -f 'tests/run|wrk|perf.sh|suite.sh|valgrind' >/dev/null; then echo "идёт другой замер или тесты" >&2; exit 2; fi
export EVAL_DB_PREFIX=s2perf_
for r in $(seq "$rounds"); do
	if ((r % 2)); then order="basetree tree4"; else order="tree4 basetree"; fi
	for t in $order; do
		echo "## round $r $t $(date +%T)" >&2
		LANGS=khrip OUT=$S/ab/regr_$t.tsv OUT_DB=$S/ab/regr_$t-db.tsv $S/$t/bench/tools/quiet.sh $S/$t/eval/perf.sh "$@" >/dev/null
	done
done
echo regr-finished
