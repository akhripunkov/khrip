#!/usr/bin/env bash
# полный набор в рабочей копии speed2: suite.sh <метка> [plain|verify|stress ...]
# адреса баз — из окружения вызывающего: MONGODB_URI, CLICKHOUSE_URL,
# CLICKHOUSE_USER, CLICKHOUSE_PASSWORD, PGHOST, PGPORT, PGUSER, PGPASSWORD
cd "${TREE:-/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed2}"
export HTTP_PORT=20181 CORO_PORT=20183 TLS_PORT=20190 PG_PORT=20290 W_METEO=20501 W_HOOK=20502 W_APP=20503 W_TICK=20504 EVAL_PORT=20380 EVAL_DB_PREFIX=s2_ CLICKHOUSE_MOCK_PORT=20371
L=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/s2/logs
mkdir -p "$L"
tag=$1; shift
for mode in "$@"; do
	log=$L/$tag-$mode.log
	date >"$log"
	case $mode in
	plain) env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS tests/run.sh >>"$log" 2>&1 ;;
	verify) KHRIP_GC_VERIFY=1 tests/run.sh >>"$log" 2>&1 ;;
	stress) KHRIP_GC_STRESS=1 tests/run.sh >>"$log" 2>&1 ;;
	esac
	echo "exit $?" >>"$log"
	date >>"$log"
done
