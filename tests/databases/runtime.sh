#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
KHC=${KHC:-build/khc}
if [[ -z ${MONGODB_URI:-} || -z ${CLICKHOUSE_URL:-} ]]; then
    echo 'shared database runtime skipped: set MONGODB_URI and CLICKHOUSE_URL'
    exit 0
fi
runtime_tmp=$(mktemp -d)
trap 'rm -rf "$runtime_tmp"' EXIT
"$KHC" -o "$runtime_tmp/server" tests/databases/runtime.kh
python3 tests/databases/runtime.py "$runtime_tmp/server"
