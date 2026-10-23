#!/usr/bin/env bash
# Тесты компилятора.
#   tests/run/*.kh    — вывод сравнивается с .out, код выхода — с комментарием
#                       «// exit: N» (по умолчанию 0); с комментариями
#                       «// env: ИМЯ=значение ...» — по запуску на каждый
#                       (пустой «// env:» — запуск как есть), и вывод у всех
#                       один: так тесты строк идут без кэша строк, с ним и в
#                       проверочном режиме (KHRIP_STRCACHE), с SIMD и без;
#   tests/errors/*.kh — не должны компилироваться; вывод компилятора должен
#                       содержать каждую строку «// expect: ...»; ключи
#                       компилятора — из «// flags: ...»;
#   tests/api/*.kh    — блоки test (khc test); вывод сравнивается с .out;
#   tests/locks/*.kh  — какие маршруты берут store на чтение (khc check --locks);
#   tests/sqlcheck/   — правильный SQL: khc check без базы не находит ошибок;
#   khc check --all-lib — вся библиотека (и не вызванные функции) и исходники
#                       компилятора (--system) проходят проверки системного кода;
#   docs/tutorial/    — примеры учебника выполняются, их тесты проходят;
#   tests/http.sh     — HTTP-сервер на Khrip отвечает правильно;
#   tests/coro.sh     — запросы, которые ждут (sleep, fetch), не держат поток;
#   tests/tls.sh      — свой TLS 1.3: криптография, сертификаты, рукопожатия;
#   tests/pg.sh       — клиент PostgreSQL на временном сервере;
#   tests/weather.sh  — погодный бэкенд: fetch, every, сохранение store;
#   eval/solutions/*/khrip — решения задач проверки проходят eval/run.sh.
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
	mapfile -t envs < <(sed -n 's|^// env: *||p' "$src")
	[[ ${#envs[@]} -eq 0 ]] && envs=("")
	for e in "${envs[@]}"; do
		# shellcheck disable=SC2086
		env $e "$tmp/$name" >"$tmp/$name.out" 2>"$tmp/$name.stderr"
		got_exit=$?
		if ! diff -u "tests/run/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
			failed "$src${e:+ ($e)}" "вывод отличается от ожидаемого"
			cat "$tmp/$name.diff"
			continue
		fi
		if [[ "$got_exit" != "$want_exit" ]]; then
			failed "$src${e:+ ($e)}" "код выхода $got_exit, ожидался $want_exit; stderr: $(cat "$tmp/$name.stderr")"
			continue
		fi
		pass=$((pass + 1))
	done
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

# Примеры учебника (docs/TUTORIAL.md) и ответы к заданиям: программы
# выполняются, API проходят свои блоки test.
for src in docs/tutorial/*.kh docs/tutorial/answers/*.kh; do
	if grep -q '^route ' "$src"; then
		cmd=(test "$src")
	else
		cmd=(run "$src")
	fi
	if "$KHC" "${cmd[@]}" >"$tmp/tutorial.out" 2>&1; then
		pass=$((pass + 1))
	else
		failed "$src" "$(cat "$tmp/tutorial.out")"
	fi
done

# Системный код: строки в нём — байты (s.byte_len(), s.byte(i), s.byte_slice).
# --all-lib проверяет все функции библиотеки, а не только вызванные программой:
# с API (crud.kh) и без него — вместе с исходниками компилятора в режиме --system.
if "$KHC" check --all-lib tests/api/crud.kh >"$tmp/alllib.txt" 2>&1; then
	pass=$((pass + 1))
else
	failed "khc check --all-lib tests/api/crud.kh" "$(cat "$tmp/alllib.txt")"
fi
if "$KHC" check --system --all-lib src/*.kh >"$tmp/alllib.txt" 2>&1; then
	pass=$((pass + 1))
else
	failed "khc check --system --all-lib src/*.kh" "$(cat "$tmp/alllib.txt")"
fi

# __data_hex (есть только в библиотеке): литерал — пары шестнадцатеричных цифр,
# пробелы — только между парами. Проверяется на копии библиотеки с двумя
# функциями: правильные литералы проходят, у неправильных — по ошибке на каждый.
mkdir -p "$tmp/hexlib"
cp lib/*.kh "$tmp/hexlib/"
cat >>"$tmp/hexlib/core.kh" <<'EOF'

fn __hex_probe_ok() -> int {
    let a = __data_hex("0f AB cd")
    let b = __data_hex(" 12 34 ")
    return a + b
}

fn __hex_probe_bad() -> int {
    let a = __data_hex("A B")
    let b = __data_hex("0 1 2 3")
    let c = __data_hex("ABC")
    let d = __data_hex("0G")
    return a + b + c + d
}
EOF
printf 'fn main() {\n}\n' >"$tmp/hexmain.kh"
KHRIP_LIB="$tmp/hexlib" "$KHC" check --all-lib "$tmp/hexmain.kh" >"$tmp/hex.txt" 2>&1
if [[ $(grep -c "__data_hex takes a string literal of hex digit pairs" "$tmp/hex.txt") -eq 4 ]] && grep -q "^4 errors" "$tmp/hex.txt"; then
	pass=$((pass + 1))
else
	failed "__data_hex: проверка литералов" "$(cat "$tmp/hex.txt")"
fi

# Правильный SQL: проверка без базы не должна найти в нём ни одной ошибки.
for src in tests/sqlcheck/*.kh; do
	if "$KHC" check "$src" >"$tmp/sqlcheck.txt" 2>&1; then
		pass=$((pass + 1))
	else
		failed "$src" "ложные ошибки проверки SQL:"$'\n'"$(cat "$tmp/sqlcheck.txt")"
	fi
done

# Какие маршруты читают store параллельно: вывод khc check --locks.
for src in tests/locks/*.kh; do
	name=$(basename "$src" .kh)
	"$KHC" check --locks "$src" >"$tmp/$name.locks" 2>&1
	if ! diff -u "tests/locks/$name.out" "$tmp/$name.locks" >"$tmp/$name.diff"; then
		failed "$src" "блокировки маршрутов отличаются от ожидаемых"
		cat "$tmp/$name.diff"
		continue
	fi
	pass=$((pass + 1))
done

if [[ -f tests/http.sh ]]; then
	# shellcheck source=tests/http.sh
	source tests/http.sh
fi

if [[ -f tests/coro.sh ]] && command -v curl >/dev/null; then
	# shellcheck source=tests/coro.sh
	source tests/coro.sh
fi

if [[ -f tests/tls.sh ]] && command -v curl >/dev/null; then
	# shellcheck source=tests/tls.sh
	source tests/tls.sh
fi

if [[ -f tests/pg.sh ]]; then
	# shellcheck source=tests/pg.sh
	source tests/pg.sh
fi

if [[ -f tests/weather.sh ]] && command -v curl >/dev/null; then
	# shellcheck source=tests/weather.sh
	source tests/weather.sh
fi

# Решения задач проверки (eval/) на Khrip проходят свои сценарии запросов.
if command -v curl >/dev/null && command -v python3 >/dev/null; then
	. eval/server.sh
	for dir in eval/solutions/*/khrip; do
		task=$(basename "$(dirname "$dir")")
		if [[ -f "eval/tasks/$task/db" ]] && ! "$PSQL" -q "$EVAL_PG" -c "select 1" >/dev/null 2>&1; then
			echo "пропуск eval/$task: нет PostgreSQL ($EVAL_PG)"
			continue
		fi
		if eval/run.sh "$task" khrip >"$tmp/eval.txt" 2>&1; then
			pass=$((pass + 1))
		else
			failed "eval/$task" "$(cat "$tmp/eval.txt")"
		fi
	done
fi

echo "тестов пройдено: $pass, провалено: $fail"
[[ $fail -eq 0 ]]
