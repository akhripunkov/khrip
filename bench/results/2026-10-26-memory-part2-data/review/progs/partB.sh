#!/usr/bin/env bash
# Review re-measurements, part B: rate-mode memory, closed-loop A/B, phase, gate, mapgrow, 10-minute runs.
# All under bench/tools/quiet.sh (databases on CPUs 2-3).
set -u
D=$SCRATCH/m2
R=$D/rev
W=$D/../par/mem2
Q=$W/bench/tools/quiet.sh
P=$R/progress
step() { echo "== $(date +%T) $*" >> $P; }
export EVAL_DB_PREFIX=m2_

$Q on || exit 1
trap '$Q off' EXIT

# rate mode: arenas (item 5)
for sc_r in "shop 900" "shop 1500" "ledger 1300"; do
  set -- $sc_r
  for v in tree0 tree6 go; do
    step rate $v $1 $2
    if [[ $v == go ]]; then
      (cd $D/tree6 && RATE_MODE=1 LANGS=go RATE=$2 OUT_RATE=$R/rate-go.tsv RSS_DIR=$R/rss eval/perf.sh $1 >> $R/rate.log 2>&1)
    else
      (cd $D/$v && RATE_MODE=1 LANGS=khrip RATE=$2 OUT_RATE=$R/rate-$v.tsv RSS_DIR=$R/rss eval/perf.sh $1 >> $R/rate.log 2>&1)
    fi
  done
done

# closed-loop A/B against a6176a0
for pair in 1 2 3 4; do
  order="tree0 tree6"
  ((pair % 2 == 0)) && order="tree6 tree0"
  for t in $order; do
    for sc in shortener bank notes polls; do
      step ab $pair $t $sc
      (cd $D/$t && LANGS=khrip OUT=$R/ab-$t.tsv OUT_DB=$R/ab-db.tsv eval/perf.sh $sc >> $R/ab.log 2>&1)
    done
  done
done

step phase
(cd $D/tree6 && OUT=$R/phase bench/gc/phase.sh khrip > $R/phase.log 2>&1)
step gate
(cd $D/tree6 && DELETE=0 OUT=$R/gate bench/gc/gate.sh 60 > $R/gate.log 2>&1)
step mapgrow
(cd $D/tree6 && bench/gc/mapgrow.sh int > $R/mapgrow.txt 2>&1; bench/gc/mapgrow.sh str >> $R/mapgrow.txt 2>&1)

long() { # tree scenario tag
  step long $1 $2 $3
  (cd $D/$1 && OUT=$R/long/$2-$3 OUT_TSV=$R/long.tsv bench/mem/long.sh $2 khrip >> $R/long.log 2>&1)
}
long tree6 polls final
long tree4 polls nohold
long tree3x polls old
long tree6 notes final
long tree3x notes old
step done partB
