#!/usr/bin/env bash
# Run inside the Linux amd64 builder, or directly on Linux with the same
# dependencies and MONGODB_URI / CLICKHOUSE_URL environment variables.
set -euo pipefail
cd "$(dirname "$0")/../.."

pg_dir=""
pg_bin=""
pg_user=()
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$pg_dir" ]]; then
        "${pg_user[@]}" "$pg_bin/pg_ctl" -D "$pg_dir/data" -m immediate stop >/dev/null 2>&1 || true
        rm -rf "${pg_dir:?}"
    fi
    exit "$status"
}
trap cleanup EXIT

bash build.sh
export KHC=${KHC:-build/khc}

if [[ ${DATABASE_FULL_SUITE:-0} == 1 ]]; then
    # The ordinary PostgreSQL tests manage their own TLS/SCRAM server. The
    # three eval tasks need a separate administrative database as well.
    if [[ -z ${EVAL_PG:-} ]]; then
        for candidate in /usr/lib/postgresql/*/bin; do
            if [[ -x "$candidate/initdb" ]]; then pg_bin=$candidate; fi
        done
        if [[ -z "$pg_bin" ]]; then
            echo 'PostgreSQL initdb is required for --all' >&2
            exit 1
        fi
        pg_dir=$(mktemp -d /var/tmp/khrip-db-eval.XXXXXX)
        printf '%s\n' 'khrip_db_eval' >"$pg_dir/password"
        if [[ $(id -u) == 0 ]]; then
            pg_user=(runuser -u postgres --)
            chown -R postgres "$pg_dir"
        fi
        if ! "${pg_user[@]}" "$pg_bin/initdb" -D "$pg_dir/data" -U postgres \
            --pwfile="$pg_dir/password" -A scram-sha-256 >"$pg_dir/init.log" 2>&1; then
            cat "$pg_dir/init.log" >&2
            exit 1
        fi
        "${pg_user[@]}" "$pg_bin/pg_ctl" -D "$pg_dir/data" -l "$pg_dir/server.log" \
            -w -o "-p 18390 -h 127.0.0.1 -k $pg_dir" start >/dev/null
        export EVAL_PG='postgres://postgres:khrip_db_eval@127.0.0.1:18390/postgres?sslmode=disable'
    fi
    bash tests/run.sh
else
    # The full suite already includes these checks and both standalone scripts.
    "$KHC" check --all-lib tests/api/crud.kh
    "$KHC" check --system --all-lib src/*.kh
    bash tests/databases/compiler.sh
    bash tests/mongo.sh
    bash tests/clickhouse.sh
fi

bash tests/databases/runtime.sh

# Keep the short published examples executable as the public API evolves.
"$KHC" run examples/databases/mongo.kh
"$KHC" run examples/databases/clickhouse.kh
