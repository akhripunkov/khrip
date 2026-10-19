#!/usr/bin/env bash
# Тесты компилятора.
#   tests/run/*.kh    — собираются вместе с lib/std.kh (и библиотеками из
#                       комментария «// libs: ...»), вывод сравнивается с .out,
#                       код выхода — с комментарием «// exit: N» (по умолчанию 0);
#   tests/errors/*.kh — не должны компилироваться; сообщение об ошибке должно
#                       содержать текст из комментария «// expect: ...»;
#   tests/http.sh     — HTTP-сервер на Khrip отвечает правильно.
# Компилятор берётся из $KHC (по умолчанию build/khc).
set -uo pipefail
cd "$(dirname "$0")/.."

KHC=${KHC:-build/khc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

failed() {
	echo "FAIL $1: $2"
	fail=$((fail + 1))
}

for src in tests/run/*.kh; do
	name=$(basename "$src" .kh)
	want_exit=$(sed -n 's|^// exit: *||p' "$src" | head -1)
	want_exit=${want_exit:-0}
	libs=$(sed -n 's|^// libs: *||p' "$src" | head -1)
	# shellcheck disable=SC2086
	if ! "$KHC" -o "$tmp/$name" lib/std.kh $libs "$src" 2>"$tmp/$name.err"; then
		failed "$src" "не скомпилировалось: $(cat "$tmp/$name.err")"
		continue
	fi
	"$tmp/$name" >"$tmp/$name.out"
	got_exit=$?
	if ! diff -u "tests/run/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
		failed "$src" "вывод отличается от ожидаемого"
		cat "$tmp/$name.diff"
		continue
	fi
	if [[ "$got_exit" != "$want_exit" ]]; then
		failed "$src" "код выхода $got_exit, ожидался $want_exit"
		continue
	fi
	pass=$((pass + 1))
done

for src in tests/errors/*.kh; do
	want=$(sed -n 's|^// expect: *||p' "$src" | head -1)
	if "$KHC" -o "$tmp/err" "$src" 2>"$tmp/err.txt"; then
		failed "$src" "скомпилировалось, а должна быть ошибка"
	elif ! grep -qF -- "$want" "$tmp/err.txt"; then
		failed "$src" "ожидалось «$want», получено «$(cat "$tmp/err.txt")»"
	else
		pass=$((pass + 1))
	fi
done

# shellcheck source=tests/http.sh
source tests/http.sh

echo "тестов пройдено: $pass, провалено: $fail"
[[ $fail -eq 0 ]]
