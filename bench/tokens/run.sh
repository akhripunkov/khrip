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
echo "### TODO API (перечисление, фильтры, сортировка, статистика)"
node count.mjs $s/todo/khrip/main.kh $s/todo/csharp/Program.cs $s/todo/python/main.py $s/todo/go/main.go
echo
echo "### TODO API: Khrip v0.6 (без match, лямбд и значений по умолчанию) против v0.7"
node count.mjs $s/todo/variants/v06.kh $s/todo/khrip/main.kh
echo
echo "### Варианты синтаксиса CRUD"
node count.mjs $s/crud/variants/braces.kh $s/crud/variants/indent.kh $s/crud/variants/rust_types.kh $s/crud/khrip/main.kh
echo
echo "### Задачи бэкенда (eval/): Khrip, Python, C#, Go"
node eval.mjs
echo
echo "### Спецификация для промпта"
node spec_tokens.mjs ../../docs/KHRIP.md
