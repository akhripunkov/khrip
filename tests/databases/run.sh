#!/usr/bin/env bash
# Isolated real-server tests. No host ports or persistent data volumes.
# Usage: bash tests/databases/run.sh [--all]
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD

full=0
if [[ ${1:-} == --all ]]; then
    full=1
    shift
fi
if [[ $# != 0 ]]; then
    echo 'usage: bash tests/databases/run.sh [--all]' >&2
    exit 2
fi

mongo_image=${MONGODB_TEST_IMAGE:-mongo:8.0@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907}
clickhouse_image=${CLICKHOUSE_TEST_IMAGE:-clickhouse/clickhouse-server:25.8@sha256:0152dd511befe6a2c2ef53e930726179669b08116da78500b37c51c96ff5ee77}
builder_image=${KHRIP_TEST_IMAGE:-khrip-database-tests:local}
suffix="$(date +%s)-$$"
network="khrip-db-$suffix"
mongo="khrip-mongo-$suffix"
clickhouse="khrip-clickhouse-$suffix"
builder="khrip-builder-$suffix"

# These credentials are scoped to throwaway containers on a private network.
test_user=khrip
test_password=khrip_database_test_password

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]]; then
        docker logs --tail 40 "$mongo" 2>/dev/null || true
        docker logs --tail 40 "$clickhouse" 2>/dev/null || true
    fi
    # Official database images declare anonymous volumes. Remove those too.
    docker rm -fv "$builder" "$mongo" "$clickhouse" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker info >/dev/null
docker build --platform linux/amd64 -t "$builder_image" \
    -f tests/databases/Dockerfile tests/databases
docker network create "$network" >/dev/null

# Services use the Docker host's architecture (also works on Apple Silicon).
# Only Khrip's compiler and emitted applications need amd64 emulation.
docker run -d --name "$mongo" --network "$network" --network-alias mongo \
    -e MONGO_INITDB_ROOT_USERNAME="$test_user" \
    -e MONGO_INITDB_ROOT_PASSWORD="$test_password" \
    "$mongo_image" >/dev/null
docker run -d --name "$clickhouse" --network "$network" --network-alias clickhouse \
    --ulimit nofile=262144:262144 \
    -e CLICKHOUSE_USER="$test_user" \
    -e CLICKHOUSE_PASSWORD="$test_password" \
    -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    -e CLICKHOUSE_DB=khrip_test \
    "$clickhouse_image" >/dev/null

mongo_ready=0
clickhouse_ready=0
for _ in $(seq 120); do
    if [[ $mongo_ready == 0 ]] && docker exec "$mongo" mongosh --quiet \
        --username "$test_user" --password "$test_password" \
        --authenticationDatabase admin \
        --eval 'quit(db.adminCommand({ping: 1}).ok ? 0 : 1)' >/dev/null 2>&1; then
        mongo_ready=1
    fi
    if [[ $clickhouse_ready == 0 ]] && docker exec "$clickhouse" clickhouse-client \
        --user "$test_user" --password "$test_password" \
        --query 'SELECT 1' >/dev/null 2>&1; then
        clickhouse_ready=1
    fi
    if [[ $mongo_ready == 1 && $clickhouse_ready == 1 ]]; then
        break
    fi
    sleep 0.5
done
if [[ $mongo_ready != 1 || $clickhouse_ready != 1 ]]; then
    echo "database startup failed: mongo=$mongo_ready clickhouse=$clickhouse_ready" >&2
    exit 1
fi

# Record exact resolved images with every run. Defaults use multi-architecture
# manifest digests; image variables allow testing other server versions.
docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' "$mongo" "$clickhouse"

docker run --rm --name "$builder" --platform linux/amd64 \
    --network "$network" \
    --mount "type=bind,source=$repo,target=/work" \
    -e DATABASE_FULL_SUITE="$full" \
    -e MONGODB_URI="mongodb://$test_user:$test_password@mongo:27017/khrip_test?authSource=admin&directConnection=true" \
    -e CLICKHOUSE_URL=http://clickhouse:8123/ \
    -e CLICKHOUSE_USER="$test_user" \
    -e CLICKHOUSE_PASSWORD="$test_password" \
    "$builder_image"
