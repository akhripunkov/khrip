#!/usr/bin/env bash
# Final measurement of release 0.13.0, method v2: one batch per call.
#   batch.sh closed1 | closed2 | rate | conn | long-bank | long-notes | smoke
# Everything runs under bench/tools/quiet.sh; server on CPUs 0-1, load on 2-3.
set -uo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
D=${D:-/tmp/v013r2-data}  # where the raw rows go; copied here after each batch
mkdir -p "$D"
cd "$R/eval" || exit 2
q=("$R/bench/tools/quiet.sh")
log=$D/$1.log
{
echo "### $1 start $(date -u +%FT%TZ) $(git -C "$R" rev-parse --short HEAD)"
case $1 in
closed1)
	WARMUP=60s DURATION=60s LANGS="khrip go csharp java node bun python node-cluster" \
		OUT=$D/closed_r1.tsv OUT_DB=$D/closed_db_r1.tsv "${q[@]}" ./perf.sh ;;
closed2)
	WARMUP=60s DURATION=60s LANGS="node-cluster bun node java csharp go khrip" \
		OUT=$D/closed_r2.tsv OUT_DB=$D/closed_db_r2.tsv "${q[@]}" ./perf.sh ;;
rate)
	RATE_MODE=1 LANGS="khrip go csharp java node bun node-cluster" \
		OUT_RATE=$D/rate.tsv RSS_DIR=$D/rss "${q[@]}" ./perf.sh ;;
conn)
	RATE_MODE=1 CONN_SCALE="64 1000 10000" SCALE_RATE=500 LANGS="khrip go csharp java node bun node-cluster" \
		OUT_CONN=$D/conn.tsv RSS_DIR=$D/rss-conn "${q[@]}" ./perf.sh shortener bank ledger ;;
long-bank | long-notes)
	sc=${1#long-}
	OUT=$D/long/$sc OUT_TSV=$D/long.tsv "${q[@]}" "$R/bench/mem/long.sh" "$sc" khrip go csharp java node ;;
smoke)
	WARMUP=2s DURATION=3s LANGS="java node bun node-cluster" \
		OUT=$D/smoke_closed.tsv OUT_DB=$D/smoke_closed_db.tsv "${q[@]}" ./perf.sh bank ledger
	RATE_MODE=1 WARMUP=3s DURATION=5s LANGS="java node bun node-cluster" \
		OUT_RATE=$D/smoke_rate.tsv RSS_DIR=$D/smoke_rss "${q[@]}" ./perf.sh bank ledger
	RATE_MODE=1 CONN_SCALE="64" SCALE_RATE=500 SCALE_WARMUP=3s SCALE_WINDOW=5 LANGS="java node-cluster" \
		OUT_CONN=$D/smoke_conn.tsv RSS_DIR=$D/smoke_rss "${q[@]}" ./perf.sh ledger
	WARMUP=3 DURATION=10 IDLE_MAX=20 OUT=$D/smoke_long OUT_TSV=$D/smoke_long.tsv "${q[@]}" "$R/bench/mem/long.sh" bank csharp java node
	;;
*) echo "batch?"; exit 2 ;;
esac
echo "### $1 end $(date -u +%FT%TZ) status $?"
} >>"$log" 2>&1
