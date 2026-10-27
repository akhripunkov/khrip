#!/usr/bin/env bash
# Review re-measurements, part C: tree7 = 49e9055 (hold capped halfway to the hard limit).
set -u
D=$SCRATCH/m2
R=$D/rev
W=$D/../par/mem2
Q=$W/bench/tools/quiet.sh
P=$R/progress
step() { echo "== $(date +%T) $*" >> $P; }
khc() { local t=$1; shift; KHRIP_LIB=$D/$t/lib $D/$t/build/khc "$@"; }
cd $R
step partC copygrow hold
echo "tree7: $(khc tree7 test copygrow2.kh 2>&1 | grep -E 'after' | tr '\n' ' ')" >> copygrow.txt
KHRIP_GC_LOG=1 khc tree7 -o hold_tree7 hold.kh
BIN=$R/hold_tree7 bash $R/hold.sh > hold_tree7.txt 2>&1
echo "tree7: $(khc tree7 test hold_test.kh 2>&1 | grep -E 'before|growing|after' | tr '\n' ' ')" >> hold_test.txt
$Q on || exit 1
trap '$Q off' EXIT
step mapgrow tree5 tree7
for t in tree5 tree7; do
  (cd $D/$t && bench/gc/mapgrow.sh int > $R/mapgrow-int-$t.txt 2>&1)
done
step ladder
trees=(tree0 tree5 tree7)
for round in 1 2 3 4 5 6; do
  for i in 0 1 2; do
    t=${trees[$(( (i + round) % 3 ))]}
    for sc in shortener bank notes polls; do
      step ladder $round $t $sc
      (cd $D/$t && LANGS=khrip OUT=$R/ladder-$t.tsv OUT_DB=$R/ladder-db.tsv eval/perf.sh $sc >> $R/ladder.log 2>&1)
    done
  done
done
step phase gate tree7
(cd $D/tree7 && OUT=$R/phase7 bench/gc/phase.sh khrip > $R/phase7.log 2>&1)
(cd $D/tree7 && DELETE=0 OUT=$R/gate7 bench/gc/gate.sh 60 > $R/gate7.log 2>&1)
long() { # tree scenario tag
  step long $1 $2 $3
  (cd $D/$1 && OUT=$R/long/$2-$3 OUT_TSV=$R/long.tsv bench/mem/long.sh $2 khrip >> $R/long.log 2>&1)
}
long tree7 polls final7
long tree7 notes final7
step done partC
