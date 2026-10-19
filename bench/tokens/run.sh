#!/usr/bin/env bash
# Таблицы токенов из docs/CRITERIA.md. Нужен Node.js; зависимости ставятся один раз.
set -euo pipefail
cd "$(dirname "$0")"
[[ -d node_modules ]] || npm install --silent
s=samples
echo "### hello"
node count.mjs $s/hello/khrip/main.kh ../khrip/server.kh ../csharp/Program.cs ../go/main.go
echo
echo "### CRUD"
node count.mjs $s/crud/khrip/main.kh $s/crud/csharp/Program.cs $s/crud/python/main.py $s/crud/go/main.go
echo
echo "### Варианты синтаксиса CRUD"
node count.mjs $s/crud/variants/braces.kh $s/crud/variants/indent.kh $s/crud/variants/rust_types.kh $s/crud/khrip/main.kh
