#!/usr/bin/env bash
# ClickHouse в языке (docs/design/v0.13-drivers.md §2.8, шаги 1–2): ch "...",
# таблицы, вставки, миграции, проверки при запуске и khc test — против
# настоящего сервера (CLICKHOUSE_URL, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD).
# Каждый запуск работает в своих базах khrip_chdb_* и удаляет их.
set -euo pipefail
cd "$(dirname "$0")/.."
KHC=${KHC:-build/khc}
if [[ -z ${CLICKHOUSE_URL:-} ]]; then
    echo "SKIP typed ClickHouse (tests/chdb.sh): set CLICKHOUSE_URL"
    exit 0
fi
port=${CHDB_PORT:-$((${CLICKHOUSE_MOCK_PORT:-18371} + 10))}
proxy_port=$((port + 1))
chdb_tmp=$(mktemp -d)
base=${CLICKHOUSE_URL%/}
ch_user=${CLICKHOUSE_USER:-default}
ch_pass=${CLICKHOUSE_PASSWORD:-}
host_port=${base#*://}
host_port=${host_port#*@}
db="khrip_chdb_$$_$RANDOM"
pids=()
q() {
    curl -sS -u "$ch_user:$ch_pass" "$base/?database=$1" --data-binary "$2"
}
cleanup() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    q default "DROP DATABASE IF EXISTS $db SYNC" >/dev/null 2>&1 || true
    q default "DROP DATABASE IF EXISTS ${db}_other SYNC" >/dev/null 2>&1 || true
    rm -rf "$chdb_tmp"
}
trap cleanup EXIT
fail() {
    echo "FAIL tests/chdb.sh: $*"
    exit 1
}
# сравнить вывод программы с ожидаемым
expect_output() {
    local name=$1
    shift
    if ! "$@" >"$chdb_tmp/$name.got" 2>"$chdb_tmp/$name.err"; then
        fail "$name exited with an error: $(cat "$chdb_tmp/$name.err")"
    fi
    if ! diff -u "tests/chdb/$name.out" "$chdb_tmp/$name.got"; then
        fail "$name: the output differs"
    fi
}
wait_port() {
    for attempt in $(seq 200); do
        if curl -s -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    fail "nothing listens on port $1"
}
q default "CREATE DATABASE $db" || fail "cannot create database $db"
q default "CREATE DATABASE ${db}_other" || fail "cannot create database ${db}_other"
url="$base/$db"
other_url="${base%%://*}://$ch_user:$ch_pass@$host_port/${db}_other"

# ---- Шаг 1: ch "..." ----
q "$db" "CREATE TABLE clicks (ts DateTime, user_id UInt64, url String, country LowCardinality(String), ms UInt32) ENGINE = MergeTree ORDER BY (url, ts)" || fail "create clicks"
q "${db}_other" "CREATE TABLE marker (x UInt8) ENGINE = Memory" || fail "create marker"
q "${db}_other" "INSERT INTO marker VALUES (1), (2)" || fail "fill marker"
"$KHC" -o "$chdb_tmp/ch_lex" tests/run/ch_lex.kh
"$KHC" -o "$chdb_tmp/queries" tests/chdb/queries.kh
"$KHC" -o "$chdb_tmp/api" tests/chdb/api.kh
expect_output ch_lex env CLICKHOUSE_URL="$url" "$chdb_tmp/ch_lex"
expect_output queries env CLICKHOUSE_URL="$url" OTHER_CLICKHOUSE_URL="$other_url" "$chdb_tmp/queries"
# log_comment — место в исходнике
q default "SYSTEM FLUSH LOGS" >/dev/null
logged=$(q default "SELECT count() FROM system.query_log WHERE current_database = '$db' AND log_comment LIKE 'tests/chdb/queries.kh:%' AND type = 'QueryFinish'")
[[ "$logged" -gt 10 ]] || fail "log_comment of ch queries is not in system.query_log ($logged)"
# без адреса — отказ при запуске (S3)
if env -u CLICKHOUSE_URL "$chdb_tmp/ch_lex" >"$chdb_tmp/s3.out" 2>"$chdb_tmp/s3.err"; then
    fail "a program with ch started without CLICKHOUSE_URL"
fi
grep -qF "khrip: CLICKHOUSE_URL is not set (8 ch queries): http://user:password@host:8123/database" "$chdb_tmp/s3.err" || fail "S3 message: $(cat "$chdb_tmp/s3.err")"
# статусы в маршрутах: через посредника, которого потом закрывают (503)
python3 tests/chdb/proxy.py "$proxy_port" "${host_port%:*}" "${host_port##*:}" >"$chdb_tmp/proxy.log" 2>&1 &
pids+=($!)
wait_port "$proxy_port" 2>/dev/null || true
PORT=$port THREADS=2 CLICKHOUSE_URL="http://127.0.0.1:$proxy_port/$db" CLICKHOUSE_TIMEOUT=1000 "$chdb_tmp/api" >"$chdb_tmp/api.log" 2>&1 &
pids+=($!)
wait_port "$port"
status() {
    curl -s -o "$chdb_tmp/body" -D "$chdb_tmp/headers" -w '%{http_code}' "http://127.0.0.1:$port$1"
}
[[ $(status "/count?user=1") == 200 ]] || fail "/count: $(cat "$chdb_tmp/body")"
grep -q '"n":' "$chdb_tmp/body" || fail "/count body: $(cat "$chdb_tmp/body")"
[[ $(status "/click?ts=0") == 404 ]] || fail "/click without a row: $(cat "$chdb_tmp/body")"
[[ $(status "/parse?s=abc") == 400 ]] || fail "/parse: $(cat "$chdb_tmp/body")"
grep -q '^bad value: ' "$chdb_tmp/body" || fail "/parse body: $(cat "$chdb_tmp/body")"
! grep -q 'version' "$chdb_tmp/body" || fail "/parse body has the server version: $(cat "$chdb_tmp/body")"
[[ $(status "/huge") == 500 ]] || fail "/huge: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == "internal error" ]] || fail "/huge body: $(cat "$chdb_tmp/body")"
[[ $(status "/slow") == 503 ]] || fail "/slow: $(cat "$chdb_tmp/body")"
grep -qi '^Retry-After: 1' "$chdb_tmp/headers" || fail "/slow without Retry-After"
# срок клиента вышел — KILL QUERY: на сервере запроса больше нет
for attempt in $(seq 40); do
    running=$(q default "SELECT count() FROM system.processes WHERE query LIKE '%sleepEachRow(0.2)%' AND query NOT LIKE '%system.processes%'")
    [[ $running == 0 ]] && break
    sleep 0.1
done
[[ $running == 0 ]] || fail "the abandoned query still runs on the server"
kill "${pids[0]}"
wait "${pids[0]}" 2>/dev/null || true
[[ $(status "/count?user=1") == 503 ]] || fail "/count with ClickHouse down: $(cat "$chdb_tmp/body")"
grep -qi '^Retry-After: 1' "$chdb_tmp/headers" || fail "503 without Retry-After"
[[ $(cat "$chdb_tmp/body") == "database unavailable, try again" ]] || fail "503 body: $(cat "$chdb_tmp/body")"
grep -q 'clickhouse failed \[' "$chdb_tmp/api.log" || fail "no log line for 5xx: $(cat "$chdb_tmp/api.log")"
echo "typed ClickHouse (ch queries, statuses): ok"
