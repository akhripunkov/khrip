#!/usr/bin/env bash
# suite.sh <log> [env...]: full test suite of the tok1 worktree with real databases
log=$1
shift
cd /tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/tok1 || exit 2
env HTTP_PORT=20181 CORO_PORT=20183 TLS_PORT=20190 PG_PORT=20290 W_METEO=20501 W_HOOK=20502 W_APP=20503 W_TICK=20504 \
	EVAL_PORT=20380 EVAL_DB_PREFIX=t1_ CLICKHOUSE_MOCK_PORT=20371 \
	MONGODB_URI='mongodb://khrip:khrip-pass@127.0.0.1:27017/?authSource=admin' \
	CLICKHOUSE_URL=http://127.0.0.1:8123 CLICKHOUSE_USER=khrip CLICKHOUSE_PASSWORD=khrip-pass \
	"$@" bash tests/run.sh >"$log" 2>&1
echo "exit $?" >>"$log"
