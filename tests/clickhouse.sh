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
for name in codec protocol client admission; do
    "$KHC" -o "$ch_tmp/$name" "tests/clickhouse/$name.kh"
done
"$ch_tmp/codec"
ch_port=${CLICKHOUSE_MOCK_PORT:-18371}
python3 tests/clickhouse/protocol.py "$ch_port" >"$ch_tmp/mock.log" 2>&1 &
ch_mock_pid=$!
for attempt in $(seq 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$ch_port") 2>/dev/null; then break; fi
    sleep 0.02
done
"$ch_tmp/protocol" "$ch_port"
python3 tests/clickhouse/admission.py "$ch_tmp/admission" "http://127.0.0.1:$ch_port"
if command -v openssl >/dev/null; then
    mkdir -p "$ch_tmp/pki"
    tests/tls/gen.sh "$ch_tmp/pki" >"$ch_tmp/cert.log" 2>&1
    ch_tls_port=$((ch_port + 1))
    python3 tests/clickhouse/protocol.py "$ch_tls_port" "$ch_tmp/pki" >"$ch_tmp/tls.log" 2>&1 &
    ch_tls_pid=$!
    for attempt in $(seq 100); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$ch_tls_port") 2>/dev/null; then break; fi
        sleep 0.02
    done
    SSL_CERT_FILE="$ch_tmp/pki/root.pem" "$ch_tmp/protocol" "$ch_tls_port" tls
fi
if [[ -n ${CLICKHOUSE_URL:-} ]]; then
    "$ch_tmp/client"
else
    echo "ClickHouse server integration skipped: set CLICKHOUSE_URL (or run tests/databases/run.sh)"
fi
