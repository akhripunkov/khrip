#!/usr/bin/env bash
# Тесты компилятора.
#   tests/run/*.kh    — вывод сравнивается с .out, код выхода — с комментарием
#                       «// exit: N» (по умолчанию 0);
#   tests/errors/*.kh — не должны компилироваться; вывод компилятора должен
#                       содержать каждую строку «// expect: ...»; ключи
#                       компилятора — из «// flags: ...»;
#   tests/api/*.kh    — блоки test (khc test); вывод сравнивается с .out;
#   tests/http.sh     — HTTP-сервер на Khrip отвечает правильно;
#   tests/weather.sh  — погодный бэкенд: fetch, every, сохранение store.
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
	if ! "$KHC" -o "$tmp/$name" "$src" >"$tmp/$name.err" 2>&1; then
		failed "$src" "не скомпилировалось:"$'\n'"$(cat "$tmp/$name.err")"
		continue
	fi
	"$tmp/$name" >"$tmp/$name.out" 2>"$tmp/$name.stderr"
	got_exit=$?
	if ! diff -u "tests/run/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
		failed "$src" "вывод отличается от ожидаемого"
		cat "$tmp/$name.diff"
		continue
	fi
	if [[ "$got_exit" != "$want_exit" ]]; then
		failed "$src" "код выхода $got_exit, ожидался $want_exit; stderr: $(cat "$tmp/$name.stderr")"
		continue
	fi
	pass=$((pass + 1))
done

for src in tests/errors/*.kh; do
	flags=$(sed -n 's|^// flags: *||p' "$src" | head -1)
	# shellcheck disable=SC2086
	if "$KHC" check $flags "$src" >"$tmp/err.txt" 2>&1; then
		failed "$src" "скомпилировалось, а должна быть ошибка"
		continue
	fi
	ok=1
	while IFS= read -r want; do
		if ! grep -qF -- "$want" "$tmp/err.txt"; then
			failed "$src" "ожидалось «$want», получено:"$'\n'"$(cat "$tmp/err.txt")"
			ok=0
			break
		fi
	done < <(sed -n 's|^// expect: *||p' "$src")
	[[ $ok -eq 1 ]] && pass=$((pass + 1))
done

for src in tests/api/*.kh; do
	name=$(basename "$src" .kh)
	"$KHC" test "$src" >"$tmp/$name.out" 2>&1
	if ! diff -u "tests/api/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
		failed "$src" "вывод тестов отличается от ожидаемого"
		cat "$tmp/$name.diff"
		continue
	fi
	pass=$((pass + 1))
done

if [[ -f tests/http.sh ]]; then
	# shellcheck source=tests/http.sh
	source tests/http.sh
fi

if [[ -f tests/weather.sh ]] && command -v curl >/dev/null; then
	# shellcheck source=tests/weather.sh
	source tests/weather.sh
fi

echo "тестов пройдено: $pass, провалено: $fail"
[[ $fail -eq 0 ]]
