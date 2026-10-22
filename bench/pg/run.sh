#!/usr/bin/env bash
# Скорость разбора больших результатов: Khrip, Go (pgx), Python (asyncpg).
# Нужен PostgreSQL: DATABASE_URL (по умолчанию локальный postgres:khrip).
# Программа — на ядре 0, сервер базы делит остальные. Столбцы: язык, 300 тыс.
# чисел (мс), 100 тыс. строк по три столбца (мс).
set -euo pipefail
cd "$(dirname "$0")"
export DATABASE_URL=${DATABASE_URL:-postgres://postgres:khrip@127.0.0.1:5432/postgres?sslmode=disable}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
../../build/khc -o "$tmp/decode" decode.kh
(cd go && go build -o "$tmp/decode_go" .)
printf 'lang\tints_ms\trows_ms\n'
taskset -c 0 "$tmp/decode"
taskset -c 0 "$tmp/decode_go"
taskset -c 0 python3 decode.py
