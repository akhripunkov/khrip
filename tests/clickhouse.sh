#!/usr/bin/env bash
# Standalone tests; tests/databases/run.sh provides an authenticated real server.
set -euo pipefail
cd "$(dirname "$0")/.."
KHC=${KHC:-build/khc}
ch_tmp=$(mktemp -d)
ch_mock_pid=""
ch_tls_pid=""
cleanup() {
    for pid in "$ch_mock_pid" "$ch_tls_pid"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$ch_tmp"
}
trap cleanup EXIT
# Окно без блокировки store в __ch_run (docs/design/v0.13-store-gc.md §6.5):
# срок, пределы и байты запроса — до него; в окне — только обмен
# __dh_exchange по локальным значениям, а он не читает ChConfig.
window=$(sed -n '/^fn __ch_run(/,/^}/p' lib/clickhouse.kh | sed -n '/__store_release_keep()/,/__store_lock()/p' |
    grep -v -e '__store_release_keep()' -e '__store_lock()' -e '^ *} *$' -e '^ *if held {$')
if [[ "$window" != "    let r = __dh_exchange(u, head, rest, budget, sql, body, deadline, max, inflight)" ]] ||
    sed -n '/^fn __dh_exchange(/,/^}/p' lib/db_http.kh | grep -q -e 'ChConfig' -e 'timeout_ms' -e 'max_response_bytes' -e 'max_inflight\.'; then
    echo "FAIL __ch_run: the store-lock window must hold only __dh_exchange over local values:"
    echo "$window"
    exit 1
fi
# Mock готов, когда напечатал ready: открытого порта мало — TLS-mock слушает
# порт раньше, чем загрузит сертификат. Ждём до 10 с и падаем с его журналом.
wait_ready() {
    local log=$1 pid=$2
    for attempt in $(seq 500); do
        if grep -qx ready "$log"; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.02
    done
    echo "FAIL ClickHouse mock did not start:"
    cat "$log"
    exit 1
}
for name in codec protocol client admission; do
    "$KHC" -o "$ch_tmp/$name" "tests/clickhouse/$name.kh"
done
"$ch_tmp/codec"
ch_port=${CLICKHOUSE_MOCK_PORT:-18371}
python3 tests/clickhouse/protocol.py "$ch_port" >"$ch_tmp/mock.log" 2>&1 &
ch_mock_pid=$!
wait_ready "$ch_tmp/mock.log" "$ch_mock_pid"
"$ch_tmp/protocol" "$ch_port"
python3 tests/clickhouse/admission.py "$ch_tmp/admission" "http://127.0.0.1:$ch_port"
if command -v openssl >/dev/null; then
    mkdir -p "$ch_tmp/pki"
    tests/tls/gen.sh "$ch_tmp/pki" >"$ch_tmp/cert.log" 2>&1
    ch_tls_port=$((ch_port + 1))
    python3 tests/clickhouse/protocol.py "$ch_tls_port" "$ch_tmp/pki" >"$ch_tmp/tls.log" 2>&1 &
    ch_tls_pid=$!
    wait_ready "$ch_tmp/tls.log" "$ch_tls_pid"
    SSL_CERT_FILE="$ch_tmp/pki/root.pem" "$ch_tmp/protocol" "$ch_tls_port" tls
else
    echo 'SKIP ClickHouse https protocol: no openssl'
fi
if [[ -n ${CLICKHOUSE_URL:-} ]]; then
    "$ch_tmp/client"
else
    echo "SKIP ClickHouse integration: set CLICKHOUSE_URL (or run tests/databases/run.sh)"
fi
