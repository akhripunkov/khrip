#!/usr/bin/env bash
# Токены o200k решений eval на Khrip до и после изменения (см. count.mjs).
# Один раз ставит gpt-tokenizer 2.9.0 в eval/tokens/node_modules.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ -d "$here/node_modules/gpt-tokenizer" ]] || npm install --prefix "$here" --silent --no-audit --no-fund
exec node "$here/count.mjs" "$@"
