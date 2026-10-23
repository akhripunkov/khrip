#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
KHC=${KHC:-build/khc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$KHC" check tests/databases/codec_tx.kh
"$KHC" check --locks tests/locks/database_codecs.kh >"$tmp/locks"
diff -u tests/locks/database_codecs.out "$tmp/locks"
for src in tests/errors/tx_mongo*.kh tests/errors/tx_clickhouse*.kh tests/errors/driver_*.kh; do
    if "$KHC" check "$src" >"$tmp/errors" 2>&1; then
        echo "FAIL $src unexpectedly compiled" >&2
        exit 1
    fi
    while IFS= read -r expected; do
        if ! grep -qF -- "$expected" "$tmp/errors"; then
            echo "FAIL $src missing diagnostic: $expected" >&2
            cat "$tmp/errors" >&2
            exit 1
        fi
    done < <(sed -n 's|^// expect: *||p' "$src")
done
echo 'database compiler diagnostics: passed'
