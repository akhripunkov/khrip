#!/usr/bin/env bash
# Standalone BSON/protocol and real-server tests. MONGODB_URI points to a
# disposable MongoDB 6+ endpoint with permission to create/drop test collections.
set -euo pipefail
cd "$(dirname "$0")/.."
KHC=${KHC:-build/khc}
mongo_tmp=$(mktemp -d)
trap 'rm -rf "$mongo_tmp"' EXIT
"$KHC" -o "$mongo_tmp/codec" tests/mongo/codec.kh
"$mongo_tmp/codec"
"$KHC" -o "$mongo_tmp/wire-client" tests/mongo/wire_client.kh
python3 tests/mongo/wire_peer.py "$mongo_tmp/wire-client"
if [[ -z ${MONGODB_URI:-} ]]; then
    echo 'SKIP MongoDB integration: set MONGODB_URI or run tests/databases/run.sh'
    exit 0
fi
"$KHC" -o "$mongo_tmp/client" tests/mongo/client.kh
"$mongo_tmp/client"
