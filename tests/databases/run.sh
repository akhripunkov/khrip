#!/usr/bin/env bash
# Isolated real-server tests. No persistent data volumes.
# Usage: bash tests/databases/run.sh [--all] [--host]
#   --all   весь tests/run.sh, а не только проверки драйверов;
#   --host  без контейнера сборки: проверки идут на этой машине (нужны nasm,
#           python3, openssl, curl; для --all — PostgreSQL), серверы — в
#           контейнерах с портами на 127.0.0.1, которые выбирает docker. Так
#           стенд работает и там, где контейнеру сборки не скачать пакеты.
# Образы: MONGODB_TEST_IMAGE, CLICKHOUSE_TEST_IMAGE, KHRIP_TEST_BASE_IMAGE (база
# контейнера сборки) или общий реестр KHRIP_TEST_REGISTRY — например,
# mirror.gcr.io, когда Docker Hub ограничивает скачивания; дайджесты те же.
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD

full=0
host=0
while [[ $# != 0 ]]; do
    case $1 in
    --all) full=1 ;;
    --host) host=1 ;;
    *)
        echo 'usage: bash tests/databases/run.sh [--all] [--host]' >&2
        exit 2
        ;;
    esac
    shift
done

# Образ из Docker Hub или из реестра KHRIP_TEST_REGISTRY (официальные образы
# там лежат под library/).
image() {
    local name=$1 rest=$2
    if [[ -z ${KHRIP_TEST_REGISTRY:-} ]]; then
        echo "$name$rest"
    elif [[ $name == */* ]]; then
        echo "$KHRIP_TEST_REGISTRY/$name$rest"
    else
        echo "$KHRIP_TEST_REGISTRY/library/$name$rest"
    fi
}
mongo_image=${MONGODB_TEST_IMAGE:-$(image mongo :8.0@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907)}
clickhouse_image=${CLICKHOUSE_TEST_IMAGE:-$(image clickhouse/clickhouse-server :25.8@sha256:0152dd511befe6a2c2ef53e930726179669b08116da78500b37c51c96ff5ee77)}
base_image=${KHRIP_TEST_BASE_IMAGE:-$(image debian :bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8)}
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
if [[ $host == 0 ]]; then
    docker build --platform linux/amd64 --build-arg BASE="$base_image" -t "$builder_image" \
        -f tests/databases/Dockerfile tests/databases
fi
docker network create "$network" >/dev/null

# Services use the Docker host's architecture (also works on Apple Silicon).
# Only Khrip's compiler and emitted applications need amd64 emulation.
# С --host порты серверов открыты только на 127.0.0.1 этой машины.
ports=()
if [[ $host == 1 ]]; then
    ports=(-p 127.0.0.1::27017)
fi
docker run -d --name "$mongo" --network "$network" --network-alias mongo "${ports[@]}" \
    -e MONGO_INITDB_ROOT_USERNAME="$test_user" \
    -e MONGO_INITDB_ROOT_PASSWORD="$test_password" \
    "$mongo_image" >/dev/null
if [[ $host == 1 ]]; then
    ports=(-p 127.0.0.1::8123)
fi
# Базу khrip_test тесты создают сами (CLICKHOUSE_DATABASE). Предел файлов
# ClickHouse — не выше жёсткого предела здесь: больше docker не даст
# (rlimit: operation not permitted).
nofile=$(ulimit -Hn)
if [[ $nofile == unlimited || $nofile -gt 262144 ]]; then
    nofile=262144
fi
nofile=${CLICKHOUSE_TEST_NOFILE:-$nofile}
docker run -d --name "$clickhouse" --network "$network" --network-alias clickhouse "${ports[@]}" \
    --ulimit "nofile=$nofile:$nofile" \
    -e CLICKHOUSE_USER="$test_user" \
    -e CLICKHOUSE_PASSWORD="$test_password" \
    -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
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

if [[ $host == 1 ]]; then
    mongo_port=$(docker port "$mongo" 27017/tcp | head -1 | sed 's/.*://')
    clickhouse_port=$(docker port "$clickhouse" 8123/tcp | head -1 | sed 's/.*://')
    DATABASE_FULL_SUITE="$full" \
        MONGODB_URI="mongodb://$test_user:$test_password@127.0.0.1:$mongo_port/khrip_test?authSource=admin&directConnection=true" \
        CLICKHOUSE_URL="http://127.0.0.1:$clickhouse_port/" \
        CLICKHOUSE_USER="$test_user" \
        CLICKHOUSE_PASSWORD="$test_password" \
        bash tests/databases/inside.sh
    exit 0
fi

docker run --rm --name "$builder" --platform linux/amd64 \
    --network "$network" \
    --mount "type=bind,source=$repo,target=/work" \
    -e DATABASE_FULL_SUITE="$full" \
    -e MONGODB_URI="mongodb://$test_user:$test_password@mongo:27017/khrip_test?authSource=admin&directConnection=true" \
    -e CLICKHOUSE_URL=http://clickhouse:8123/ \
    -e CLICKHOUSE_USER="$test_user" \
    -e CLICKHOUSE_PASSWORD="$test_password" \
    "$builder_image"
