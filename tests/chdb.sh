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
    q default "DROP DATABASE IF EXISTS ${db}_s2 SYNC" >/dev/null 2>&1 || true
    q default "DROP USER IF EXISTS kh_ro_chdb_$$" >/dev/null 2>&1 || true
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
    fail "nothing listens on port $1: $(tail -n 3 "$chdb_tmp"/*.log 2>/dev/null)"
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
PORT=$port THREADS=2 CLICKHOUSE_URL="http://127.0.0.1:$proxy_port/$db" CLICKHOUSE_TIMEOUT=1000 CLICKHOUSE_MAX_RESULT=1000000 "$chdb_tmp/api" >"$chdb_tmp/api.log" 2>&1 &
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
# строка с меткой ch_null() остаётся строкой (не NULL); из параметра запроса
# метка не приходит: байт 0xFF — не UTF-8, это 400
[[ $(status "/sentinel") == 200 ]] || fail "/sentinel: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == '{"len":11,"quoted":11,"isnull":false,"n":0}' ]] || fail "a str parameter became NULL: $(cat "$chdb_tmp/body")"
# ответ больше CLICKHOUSE_MAX_RESULT: 500, без Retry-After, без повтора
[[ $(status "/big?n=10") == 200 ]] || fail "/big small: $(cat "$chdb_tmp/body")"
[[ $(status "/big?n=1000000") == 500 ]] || fail "/big over the cap: $(cat "$chdb_tmp/body")"
! grep -qi '^Retry-After' "$chdb_tmp/headers" || fail "/big over the cap has Retry-After"
grep -q 'add LIMIT or aggregate' "$chdb_tmp/api.log" || fail "no LIMIT hint for a large result: $(cat "$chdb_tmp/api.log")"
q default "SYSTEM FLUSH LOGS" >/dev/null
big_runs=$(q default "SELECT count() FROM system.query_log WHERE current_database = '$db' AND type = 'QueryStart' AND log_comment LIKE 'tests/chdb/api.kh:%' AND startsWith(query, 'SELECT number FROM numbers(')")
# 1 — /big?n=10, 1 — /big?n=1000000 (без повтора)
[[ $big_runs == 2 ]] || fail "a result over the cap ran $big_runs queries (want 2: no retry)"
# значение параметра: до 128 КиБ — запрос, больше — 400
[[ $(status "/ids?n=8000") == 200 ]] || fail "/ids 8000 values: $(cat "$chdb_tmp/body")"
[[ $(status "/ids?n=20000") == 400 ]] || fail "/ids 20000 values: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == "bad value: {ids} is too long ("*" bytes as a ClickHouse parameter, at most 131072)" ]] || fail "/ids body: $(cat "$chdb_tmp/body")"
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
kill "${pids[1]}"
wait "${pids[1]}" 2>/dev/null || true

# ---- Шаг 2: таблицы, вставки, миграции, проверки при запуске, khc test ----
fresh() {
    q default "DROP DATABASE IF EXISTS $1 SYNC" >/dev/null
    q default "CREATE DATABASE $1" || fail "cannot create database $1"
}
step2="${db}_s2"
fresh "$step2"
s2_url="$base/$step2"
for name in tables startup migfail readonly readonly_writer p3 clicks; do
    "$KHC" -o "$chdb_tmp/$name" "tests/chdb/$name.kh"
done
# вставки в настоящие типы, none → DEFAULT, dedup, async_insert, DbResult
expect_output tables env CLICKHOUSE_URL="$s2_url" "$chdb_tmp/tables"
# проверки при запуске: все ошибки сразу, затем выход 1
fresh "$step2"
for t in "s12 (id UInt64, ts DateTime)" "s13 (id UInt64, note String)" "s14 (id UInt64, amount Decimal(12, 2))" "s21 (id UInt64)" "s24 (id UInt64, level Enum8('Debug' = 1, 'Info' = 2, 'Error' = 3))" "mat (id UInt64, twice UInt64 MATERIALIZED id * 2)" "s13a (id UInt64, tags Array(String) DEFAULT [])"; do
    q "$step2" "CREATE TABLE $t ENGINE = MergeTree ORDER BY id" || fail "create $t"
done
if CLICKHOUSE_URL="$s2_url" "$chdb_tmp/startup" >"$chdb_tmp/startup.out" 2>"$chdb_tmp/startup.err"; then
    fail "startup checks let a broken program start"
fi
while IFS= read -r want; do
    grep -qF -- "$want" "$chdb_tmp/startup.err" || fail "startup: expected «$want», got:"$'\n'"$(cat "$chdb_tmp/startup.err")"
done <<X
tests/chdb/startup.kh:18:7: error: table s12: column ts (DateTime) is not a field of S12Row and has no DEFAULT: rows would get 1970-01-01 00:00:00
    hint: add ts to S12Row, or DEFAULT now() to the column
tests/chdb/startup.kh:19:7: error: table s13: S13Row.note is str? but column note is String without DEFAULT: none would be written as ''
    hint: make the column Nullable(String) or give it a DEFAULT, or make the field str
tests/chdb/startup.kh:20:7: error: table s14: S14Row.amount is int, but column amount is Decimal(12, 2): an int would be read as whole units
    hint: keep cents in an Int64 column, or send a str ("12.34") or a float
tests/chdb/startup.kh:21:7: error: table s21: insert dedup needs a Replicated table or SETTINGS non_replicated_deduplication_window = N: without it a repeated insert is stored twice
tests/chdb/startup.kh:22:7: error: table s24: enum Level has Trace, but column level is Enum8('Debug' = 1, 'Info' = 2, 'Error' = 3)
tests/chdb/startup.kh:23:7: error: table mat: column twice is MATERIALIZED, so MatRow.twice cannot be inserted
tests/chdb/startup.kh:24:7: error: table nope does not exist in $step2
tests/chdb/startup.kh:25:7: error: table s13a: S13aRow.tags is [str]? but column tags is Array(String): ClickHouse arrays and maps are never NULL, so none cannot be written
    hint: make the field [str] and use an empty value for none
tests/chdb/startup.kh:29:22: error: column views is UInt64, but Views.views is str
tests/chdb/startup.kh:30:24: error: PageRow.avg_ms has no column: the query returns page
    hint: select it (or rename with AS avg_ms), or give the field a default
tests/chdb/startup.kh:31:21: error: column ts is DateTime64(3), but Ts64.ts is int
    hint: make it str, or select toUnixTimestamp(ts) AS ts (seconds) or toUnixTimestamp64Milli(ts) AS ts_ms
tests/chdb/startup.kh:33:18: error: Illegal types of arguments (Date, Int64) of function greaterOrEquals
    hint: compare a Date column with toDate({from})
tests/chdb/startup.kh:35:18: warning: not checked at start: the query fails with sample parameter values (Unknown element '' for enum); it is checked on its first run
tests/chdb/startup.kh:36:18: error: Unknown table expression identifier 'missing_table'
tests/chdb/startup.kh:37:22: error: column n can be NULL, but Maybe.n is int and has no none
tests/chdb/startup.kh:38:5: error: table gone does not exist in $step2
tests/chdb/startup.kh:39:5: error: Unknown expression or function identifier \`idd\`
tests/chdb/startup.kh:40:18: error: Unknown expression identifier \`nope\`
tests/chdb/startup.kh:41:19: error: INSERT ... SELECT puts the column ts into s12.id: ClickHouse matches the columns by position, not by name
    hint: select them in the order id, ts, or list them: INSERT INTO s12 (ts, id) SELECT ...
tests/chdb/startup.kh:44:21: error: column xs can be NULL, but Tags.xs is [int] and has no none
    hint: make it [int?]
khrip: 19 ClickHouse declaration(s) or ch statement(s) do not match the server
X
# миграции: S22, проверка без применения, ./app migrate, изменённая миграция
fresh "$step2"
if CLICKHOUSE_URL="$s2_url" "$chdb_tmp/migfail" >/dev/null 2>"$chdb_tmp/migfail.err"; then
    fail "a failed migration let the program start"
fi
grep -qF "khrip: ClickHouse migration ch 1 failed at statement 2 of 3: Table $step2.m1 already exists" "$chdb_tmp/migfail.err" || fail "S22: $(cat "$chdb_tmp/migfail.err")"
fresh "$step2"
cat >"$chdb_tmp/mig.kh" <<'X'
migration ch 1 `CREATE TABLE t1 (id UInt64) ENGINE = MergeTree ORDER BY id`
fn main() {
    let n: int = ch "SELECT count() FROM t1"
    print(n)
}
X
sed 's/ORDER BY id`/ORDER BY (id)`/' "$chdb_tmp/mig.kh" >"$chdb_tmp/mig_edited.kh"
"$KHC" -o "$chdb_tmp/mig" "$chdb_tmp/mig.kh"
"$KHC" -o "$chdb_tmp/mig_edited" "$chdb_tmp/mig_edited.kh"
if DATABASE_MIGRATE=check CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig" >/dev/null 2>"$chdb_tmp/mig.err"; then
    fail "DATABASE_MIGRATE=check started without the migration"
fi
grep -qF "khrip: ClickHouse migration ch 1 is not applied (DATABASE_MIGRATE=check): run ./app migrate" "$chdb_tmp/mig.err" || fail "check mode: $(cat "$chdb_tmp/mig.err")"
CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig" migrate 2>"$chdb_tmp/mig.err" || fail "./app migrate: $(cat "$chdb_tmp/mig.err")"
grep -qF "khrip: the database is up to date" "$chdb_tmp/mig.err" || fail "./app migrate output: $(cat "$chdb_tmp/mig.err")"
[[ $(DATABASE_MIGRATE=check CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig" 2>/dev/null) == 0 ]] || fail "check mode after migrate"
if CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_edited" >/dev/null 2>"$chdb_tmp/mig.err"; then
    fail "an edited migration let the program start"
fi
grep -qF "khrip: ClickHouse migration ch 1 was changed after it was applied" "$chdb_tmp/mig.err" || fail "edited migration: $(cat "$chdb_tmp/mig.err")"
# номер меньше применённого — отказ, как у PostgreSQL
fresh "$step2"
for name in mig_order1 mig_order2 mig_seed mig_two; do
    "$KHC" -o "$chdb_tmp/$name" "tests/chdb/$name.kh"
done
CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_order1" >/dev/null 2>"$chdb_tmp/mig.err" || fail "migrations 1 and 3: $(cat "$chdb_tmp/mig.err")"
if CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_order2" >/dev/null 2>"$chdb_tmp/mig.err"; then
    fail "migration 2 after the applied 3 was applied"
fi
grep -qF "khrip: ClickHouse migration ch 2 is older than the applied migration ch 3: renumber it to 4" "$chdb_tmp/mig.err" || fail "out-of-order migration: $(cat "$chdb_tmp/mig.err")"
# одновременные запуски: миграция с данными применяется один раз (замок базы)
fresh "$step2"
mig_pids=()
for k in 1 2 3 4; do
    CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_seed" migrate >"$chdb_tmp/seed$k.out" 2>&1 &
    mig_pids+=($!)
done
for pid in "${mig_pids[@]}"; do
    wait "$pid" || fail "concurrent ./app migrate: $(cat "$chdb_tmp"/seed*.out)"
done
[[ $(q "$step2" "SELECT count() FROM seed") == 3 ]] || fail "concurrent starts applied the seed migration $(q "$step2" "SELECT count() FROM seed") / 3 rows"
[[ $(q "$step2" "SELECT count() FROM khrip_migrations") == 1 ]] || fail "khrip_migrations after concurrent starts"
[[ $(q "$step2" "EXISTS TABLE khrip_migrations_lock") == 0 ]] || fail "the migration lock was not released"
# два соединения к одной базе — у каждого своя migration 1
fresh "$step2"
METRICS_CLICKHOUSE_URL="${base%%://*}://$ch_user:$ch_pass@$host_port/$step2" CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_two" >/dev/null 2>"$chdb_tmp/mig.err" || fail "two connections to one database: $(cat "$chdb_tmp/mig.err")"
[[ $(q "$step2" "SELECT arrayStringConcat(groupArray(name), ',') FROM (SELECT name FROM khrip_migrations ORDER BY name)") == "1,metrics/1" ]] || fail "migration records of two connections: $(q "$step2" "SELECT name FROM khrip_migrations")"
# пользователь с readonly=1: чтение без настроек проходит, запись — S20
fresh "$step2"
ro_user="kh_ro_chdb_$$"
q "$step2" "CREATE TABLE ro_data (x UInt8) ENGINE = MergeTree ORDER BY x" || fail "create ro_data"
q "$step2" "INSERT INTO ro_data VALUES (1), (2)" || fail "fill ro_data"
q default "CREATE USER $ro_user IDENTIFIED WITH plaintext_password BY 'ro-pass' SETTINGS readonly = 1" || fail "create readonly user"
q default "GRANT SELECT ON $step2.* TO $ro_user" || fail "grant readonly user"
ro_url="${base%%://*}://$ro_user:ro-pass@$host_port/$step2"
ro_out=$(env -u CLICKHOUSE_USER -u CLICKHOUSE_PASSWORD CLICKHOUSE_URL="$ro_url" "$chdb_tmp/readonly" 2>"$chdb_tmp/ro.err") || { q default "DROP USER $ro_user" >/dev/null; fail "readonly reader: $(cat "$chdb_tmp/ro.err")"; }
[[ $ro_out == "2 2" ]] || { q default "DROP USER $ro_user" >/dev/null; fail "readonly reader output: $ro_out"; }
if env -u CLICKHOUSE_USER -u CLICKHOUSE_PASSWORD CLICKHOUSE_URL="$ro_url" "$chdb_tmp/readonly_writer" >/dev/null 2>"$chdb_tmp/ro.err"; then
    q default "DROP USER $ro_user" >/dev/null
    fail "a writer started with a readonly user"
fi
grep -qF "khrip: ClickHouse user $ro_user is read-only, but the program writes (tests/chdb/readonly_writer.kh:6:5)" "$chdb_tmp/ro.err" || fail "S20: $(cat "$chdb_tmp/ro.err")"
# readonly и DATABASE_MIGRATE=check с применёнными миграциями — программа только читает
CLICKHOUSE_URL="$s2_url" "$chdb_tmp/mig_seed" migrate >/dev/null 2>&1 || fail "seed for the readonly check"
[[ $(env -u CLICKHOUSE_USER -u CLICKHOUSE_PASSWORD DATABASE_MIGRATE=check CLICKHOUSE_URL="$ro_url" "$chdb_tmp/mig_seed" 2>"$chdb_tmp/ro.err") == 3 ]] || fail "readonly reader with migrations in check mode: $(cat "$chdb_tmp/ro.err")"
q default "DROP USER $ro_user" >/dev/null
# именованное соединение: таблицы in ИМЯ, migration ИМЯ N, ch ИМЯ; none — отказ
fresh "$step2"
"$KHC" -o "$chdb_tmp/named" tests/chdb/named.kh
[[ $(METRICS_CLICKHOUSE_URL="${base%%://*}://$ch_user:$ch_pass@$host_port/$step2" "$chdb_tmp/named" 2>/dev/null) == 2 ]] || fail "named connection"
if env -u METRICS_CLICKHOUSE_URL "$chdb_tmp/named" >/dev/null 2>"$chdb_tmp/named.err"; then
    fail "a none connection started"
fi
grep -qF 'tests/chdb/named.kh:3:12: error: clickhouse metrics = env("METRICS_CLICKHOUSE_URL") is none: the connection needs a URL' "$chdb_tmp/named.err" || fail "none connection: $(cat "$chdb_tmp/named.err")"
# khc test: своя временная база, удаляется в конце
before=$(q default "SELECT count() FROM system.databases WHERE startsWith(name, 'khrip_test_')")
KHRIP_TEST_CLICKHOUSE_URL="$base/default" KHRIP_TEST_CLICKHOUSE_USER="$ch_user" KHRIP_TEST_CLICKHOUSE_PASSWORD="$ch_pass" "$KHC" test tests/chdb/khc_test.kh >"$chdb_tmp/khc_test.out" 2>"$chdb_tmp/khc_test.err" || fail "khc test: $(cat "$chdb_tmp/khc_test.out" "$chdb_tmp/khc_test.err")"
diff -u tests/chdb/khc_test.out "$chdb_tmp/khc_test.out" || fail "khc test output differs"
after=$(q default "SELECT count() FROM system.databases WHERE startsWith(name, 'khrip_test_')")
[[ $after == "$before" ]] || fail "khc test left its temporary database ($before before, $after after)"
# проверки при запуске или миграция не прошли — временная база всё равно удалена
for bad in khc_test_bad khc_test_migfail; do
    if KHRIP_TEST_CLICKHOUSE_URL="$base/default" KHRIP_TEST_CLICKHOUSE_USER="$ch_user" KHRIP_TEST_CLICKHOUSE_PASSWORD="$ch_pass" "$KHC" test "tests/chdb/$bad.kh" >"$chdb_tmp/$bad.out" 2>&1; then
        fail "$bad: khc test passed"
    fi
    after=$(q default "SELECT count() FROM system.databases WHERE startsWith(name, 'khrip_test_')")
    [[ $after == "$before" ]] || fail "$bad: khc test left its temporary database ($before before, $after after): $(cat "$chdb_tmp/$bad.out")"
done
# P3 и clicks на настоящей схеме (migration ch 1): вставки и отчёты по HTTP
fresh "$step2"
PORT=$port THREADS=2 CLICKHOUSE_URL="$s2_url" "$chdb_tmp/p3" >"$chdb_tmp/p3.log" 2>&1 &
pids+=($!)
wait_port "$port"
post() {
    curl -s -o "$chdb_tmp/body" -w '%{http_code}' -X POST "http://127.0.0.1:$port$1" -d "$2"
}
[[ $(post /events '[{"user_id":1,"page":"/","ms":1.5},{"user_id":2,"page":"/","ms":2.5},{"user_id":1,"page":"/a","ms":3}]') == 202 ]] || fail "P3 insert: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == '{"inserted":3}' ]] || fail "P3 insert body: $(cat "$chdb_tmp/body")"
[[ $(post /events '[{"user_id":-1,"page":"/","ms":1}]') == 400 ]] || fail "P3 negative user_id: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == "bad value: events.user_id: -1 is out of range for UInt64" ]] || fail "P3 400 body: $(cat "$chdb_tmp/body")"
[[ $(status "/stats/pages?from=0&to=9999999999") == 200 ]] || fail "P3 report: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == '[{"page":"/","views":2,"users":2,"avg_ms":2},{"page":"/a","views":1,"users":1,"avg_ms":3}]' ]] || fail "P3 report body: $(cat "$chdb_tmp/body")"
kill "${pids[-1]}"
wait "${pids[-1]}" 2>/dev/null || true
fresh "$step2"
PORT=$port THREADS=2 CLICKHOUSE_URL="$s2_url" "$chdb_tmp/clicks" >"$chdb_tmp/clicks.log" 2>&1 &
pids+=($!)
wait_port "$port"
[[ $(post /clicks '[{"user_id":1,"url":"/","country":"DE","ms":10},{"user_id":2,"url":"/","country":"US","ms":20},{"user_id":1,"url":"/b","country":"it'"'"'s%","ms":30}]') == 202 ]] || fail "clicks insert: $(cat "$chdb_tmp/body")"
[[ $(status "/top?from=0&to=9999999999") == 200 ]] || fail "clicks top: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == '[{"url":"/","hits":2,"users":2,"p95_ms":19.5},{"url":"/b","hits":1,"users":1,"p95_ms":30}]' ]] || fail "clicks top body: $(cat "$chdb_tmp/body")"
[[ $(status "/top?from=0&to=9999999999&country=it's%25") == 200 ]] || fail "clicks top country: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == '[{"url":"/b","hits":1,"users":1,"p95_ms":30}]' ]] || fail "clicks country with ' and %: $(cat "$chdb_tmp/body")"
[[ $(status "/top?from=0&to=9999999999&country=%25") == 200 && $(cat "$chdb_tmp/body") == '[]' ]] || fail "clicks country % matches literally: $(cat "$chdb_tmp/body")"
[[ $(status "/daily?from=0&to=9999999999") == 200 ]] || fail "clicks daily: $(cat "$chdb_tmp/body")"
grep -q '"hits":3' "$chdb_tmp/body" || fail "clicks daily body: $(cat "$chdb_tmp/body")"
[[ $(post /clicks '[{"user_id":5,"url":"/","country":"DE","ms":-10}]') == 400 ]] || fail "clicks negative ms: $(cat "$chdb_tmp/body")"
kill "${pids[-1]}"
wait "${pids[-1]}" 2>/dev/null || true
# таблицу изменили после запуска: план вставки — заново, один повтор
fresh "$step2"
"$KHC" -o "$chdb_tmp/replan" tests/chdb/replan.kh
PORT=$port THREADS=2 CLICKHOUSE_URL="$s2_url" "$chdb_tmp/replan" >"$chdb_tmp/replan.log" 2>&1 &
pids+=($!)
wait_port "$port"
[[ $(post /p '{"id":1,"v":5}') == 201 ]] || fail "replan first insert: $(cat "$chdb_tmp/body")"
q "$step2" "ALTER TABLE pr MODIFY COLUMN v UInt8" || fail "alter pr"
[[ $(post /p '{"id":2,"v":7}') == 201 ]] || fail "insert after ALTER MODIFY COLUMN: $(cat "$chdb_tmp/body") $(cat "$chdb_tmp/replan.log")"
grep -qF "tests/chdb/replan.kh:11:5: table pr changed after start: the insert plan was rebuilt" "$chdb_tmp/replan.log" || fail "replan log: $(cat "$chdb_tmp/replan.log")"
[[ $(post /p '{"id":3,"v":300}') == 400 ]] || fail "the rebuilt plan lets 300 into UInt8: $(cat "$chdb_tmp/body")"
[[ $(cat "$chdb_tmp/body") == "bad value: pr.v: 300 is out of range for UInt8" ]] || fail "replan 400 body: $(cat "$chdb_tmp/body")"
[[ $(status /p) == 200 && $(cat "$chdb_tmp/body") == 12 ]] || fail "rows after replan: $(cat "$chdb_tmp/body")"
q "$step2" "ALTER TABLE pr DROP COLUMN s" || fail "drop pr.s"
[[ $(post /p '{"id":4,"v":1}') == 500 ]] || fail "insert into a table without the field's column: $(cat "$chdb_tmp/body")"
grep -qF "tests/chdb/replan.kh:11:5: error: table pr: P.s has no column" "$chdb_tmp/replan.log" || fail "replan error log: $(cat "$chdb_tmp/replan.log")"
echo "typed ClickHouse (ch queries, statuses, tables, migrations, startup checks, khc test): ok"
