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
# Окно без блокировки store в mongo_command (docs/design/v0.13-store-gc.md
# §6.5): всё, что читает client и command, — до него; в окне — только обмен
# __mongo_run(q), а он не читает ни Mongo, ни Bson пользователя.
window=$(sed -n '/^fn mongo_command(/,/^}/p' lib/mongo.kh | sed -n '/__store_release_keep()/,/__store_lock()/p' |
    grep -v -e '__store_release_keep()' -e '__store_lock()' -e '^ *} *$' -e '^ *if held {$')
if [[ "$window" != "    let result = __mongo_run(q)" ]] ||
    sed -n '/^fn __mongo_run(/,/^}/p' lib/mongo.kh | grep -q -e 'client\.' -e 'command\.'; then
    echo "FAIL mongo_command: the store-lock window must hold only __mongo_run(q):"
    echo "$window"
    exit 1
fi
# Очередь пула (С7) — без сервера: блоки мест не подключаются.
"$KHC" -o "$mongo_tmp/pool" tests/mongo/pool.kh
python3 tests/mongo/pool.py "$mongo_tmp/pool"
"$KHC" -o "$mongo_tmp/wire-client" tests/mongo/wire_client.kh
python3 tests/mongo/wire_peer.py "$mongo_tmp/wire-client"
# TLS к настоящему mongod в своём контейнере (В7); без docker — строка SKIP.
KHC="$KHC" bash tests/mongo/tls.sh
if [[ -z ${MONGODB_URI:-} ]]; then
    echo 'SKIP MongoDB integration: set MONGODB_URI or run tests/databases/run.sh'
    exit 0
fi
"$KHC" -o "$mongo_tmp/client" tests/mongo/client.kh
"$mongo_tmp/client"
# В запросе (своя арена у каждого теста): память на больших объёмах и курсоры,
# которые запрос не закрыл.
KHRIP_MONGO_REQUEST="khrip_request_$$_$RANDOM" "$KHC" test tests/mongo/request.kh
