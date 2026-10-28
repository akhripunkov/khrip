#!/usr/bin/env bash
# ab.sh: one ABBA round of eval/perf.sh (khrip only) for bank, catalog, shop;
# A — solutions at e1203ad, B — rewritten; both built by the branch compiler.
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad
Q=$S/par/tok1/bench/tools/quiet.sh
for sc in bank catalog shop; do
	for v in A B B A; do
		echo "== $sc $v"
		LANGS=khrip "$Q" "$S/t/ab$v/eval/perf.sh" "$sc" 2>/dev/null | sed "s/^/$v /"
	done
done
