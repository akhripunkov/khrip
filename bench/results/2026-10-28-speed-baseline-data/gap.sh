#!/usr/bin/env bash
# gap.sh closed|rate [rounds] [rate-pairs...] — Khrip против C# на catalog и bookings
#
# closed: eval/perf.sh (замкнутый цикл, 64 соединения, прогрев 3 с, замер 10 с),
#         круги с чередованием порядка языков (khrip csharp / csharp khrip)
# rate:   RATE_MODE=1 eval/perf.sh (wrk2, постоянная частота, прогрев 60 с,
#         замер 60 с); пары «сценарий=частота», например catalog=2800 bookings=3000
#
# Всё под bench/tools/quiet.sh; строки — в эту папку (closed.tsv, rate.tsv).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
mode=$1
rounds=${2:-3}
shift 2 || shift $#
if pgrep -x wrk >/dev/null || pgrep -f '^(/usr)?(/bin/)?bash [^ ]*(perf|run)\.sh' >/dev/null; then
	echo "gap.sh: идёт другой замер" >&2
	exit 2
fi
for r in $(seq "$rounds"); do
	if ((r % 2)); then order="khrip csharp"; else order="csharp khrip"; fi
	case $mode in
	closed)
		for sc in catalog bookings; do
			for lang in $order; do
				echo "## round $r $sc $lang $(date +%T)" >&2
				LANGS=$lang OUT=$here/closed.tsv "$root/bench/tools/quiet.sh" "$root/eval/perf.sh" "$sc"
			done
		done
		;;
	rate)
		for pair in "$@"; do
			sc=${pair%%=*}
			rate=${pair#*=}
			for lang in $order; do
				echo "## round $r $sc@$rate $lang $(date +%T)" >&2
				RATE_MODE=1 RATE=$rate LANGS=$lang OUT_RATE=$here/rate.tsv RSS_DIR=$here/rss \
					"$root/bench/tools/quiet.sh" "$root/eval/perf.sh" "$sc"
			done
		done
		;;
	esac
done
