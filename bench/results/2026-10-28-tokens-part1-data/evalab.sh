#!/usr/bin/env bash
# evalab.sh: every eval task, old (e1203ad) and new solution, eval/run.sh with response logs
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad
cd $S/par/tok1 || exit 2
out=$S/t/evalab
mkdir -p "$out"
export EVAL_PORT=20380 EVAL_DB_PREFIX=t1_
for t in $(ls eval/solutions); do
	for v in old new; do
		dir=$S/evalold/$t
		[[ $v == new ]] && dir=$PWD/eval/solutions/$t/khrip
		rm -f "$out/$t.$v.log"
		EVAL_LOG="$out/$t.$v.log" eval/run.sh "$t" khrip "$dir" >"$out/$t.$v.txt" 2>&1
		echo "$t $v exit=$? $(grep -c '' "$out/$t.$v.log") checks, $(grep -c '^FAIL' "$out/$t.$v.txt") FAIL"
	done
done
