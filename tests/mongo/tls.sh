#!/usr/bin/env bash
# TLS к настоящему mongod (В7): контейнер с --tlsMode requireTLS, свой CA
# (tests/tls/gen.sh) и tlsAllowConnectionsWithoutCertificates. С tlsCAFile
# mongod 7+ в каждом рукопожатии просит сертификат клиента (CertificateRequest).
# Второй контейнер — без tlsAllowConnectionsWithoutCertificates: ему сертификат
# клиента обязателен, и ошибка должна это называть.
# Без docker или образа — строка SKIP и успешный выход. Образ —
# MONGODB_TEST_IMAGE, иначе первый найденный локально или скачанный из
# mongo:8.0 и mirror.gcr.io/library/mongo:8.0. Запускается из tests/mongo.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
KHC=${KHC:-build/khc}

skip() {
    echo "SKIP MongoDB TLS: $1"
    exit 0
}
command -v docker >/dev/null || skip "no docker"
command -v openssl >/dev/null || skip "no openssl"
docker info >/dev/null 2>&1 || skip "docker daemon is not available"
image=${MONGODB_TEST_IMAGE:-}
if [[ -z "$image" ]]; then
    for candidate in mongo:8.0 mirror.gcr.io/library/mongo:8.0; do
        if docker image inspect "$candidate" >/dev/null 2>&1; then
            image=$candidate
            break
        fi
    done
fi
if [[ -z "$image" ]]; then
    for candidate in mongo:8.0 mirror.gcr.io/library/mongo:8.0; do
        if docker pull -q "$candidate" >/dev/null 2>&1; then
            image=$candidate
            break
        fi
    done
fi
[[ -n "$image" ]] || skip "no MongoDB image (set MONGODB_TEST_IMAGE)"

tls_tmp=$(mktemp -d)
name="khrip-mongo-tls-$$-$RANDOM"
strict="$name-strict"
cleanup() {
    local status=$?
    trap - EXIT
    if [[ $status != 0 ]]; then
        docker logs --tail 10 "$name" 2>&1 | tail -10 || true
        docker logs --tail 10 "$strict" 2>&1 | tail -10 || true
    fi
    docker rm -fv "$name" "$strict" >/dev/null 2>&1 || true
    rm -rf "$tls_tmp"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$tls_tmp/pki"
tests/tls/gen.sh "$tls_tmp/pki"
# mongod в контейнере работает от своего пользователя: файлы читаемы всем
cat "$tls_tmp/pki/leaf.pem" "$tls_tmp/pki/inter.pem" "$tls_tmp/pki/leaf.key" >"$tls_tmp/pki/server.pem"
chmod 755 "$tls_tmp" "$tls_tmp/pki"
chmod 644 "$tls_tmp/pki/server.pem" "$tls_tmp/pki/root.pem"
"$KHC" -o "$tls_tmp/tls" tests/mongo/tls.kh

# порт на хосте выбирает docker: параллельные прогоны не сталкиваются
start() {
    docker run -d --name "$1" -p 127.0.0.1::27017 \
        --mount "type=bind,source=$tls_tmp/pki,target=/tls,readonly" \
        "$image" --tlsMode requireTLS --tlsCertificateKeyFile /tls/server.pem \
        --tlsCAFile /tls/root.pem "${@:2}" >/dev/null
}
started() {
    for _ in $(seq 240); do
        if docker logs "$1" 2>&1 | grep -q '"Waiting for connections"'; then
            return 0
        fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) != true ]]; then
            break
        fi
        sleep 0.25
    done
    echo "FAIL MongoDB TLS: mongod $1 did not start"
    exit 1
}
start "$name" --tlsAllowConnectionsWithoutCertificates
start "$strict"
started "$name"
started "$strict"
port=$(docker port "$name" 27017/tcp | head -1 | sed 's/.*://')
strict_port=$(docker port "$strict" 27017/tcp | head -1 | sed 's/.*://')
MONGO_TLS_URI="mongodb://127.0.0.1:$port/?tls=true&tlsCAFile=$tls_tmp/pki/root.pem&directConnection=true" \
    MONGO_TLS_FOREIGN="mongodb://127.0.0.1:$port/?tls=true&tlsCAFile=$tls_tmp/pki/other.pem" \
    MONGO_TLS_STRICT="mongodb://127.0.0.1:$strict_port/?tls=true&tlsCAFile=$tls_tmp/pki/root.pem" \
    "$tls_tmp/tls"
