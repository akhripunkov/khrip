#!/usr/bin/env bash
# Тесты компилятора.
#   tests/run/*.kh    — вывод сравнивается с .out, код выхода — с комментарием
#                       «// exit: N» (по умолчанию 0); с комментариями
#                       «// env: ИМЯ=значение ...» — по запуску на каждый
#                       (пустой «// env:» — запуск как есть), и вывод у всех
#                       один: так тесты строк идут без кэша строк, с ним и в
#                       проверочном режиме (KHRIP_STRCACHE), с SIMD и без;
#                       «// build-env: ИМЯ=значение» — окружение компилятора
#                       (KHRIP_GC_VERIFY=1 включает в программу проверки
#                       сборщика);
#   tests/errors/*.kh — не должны компилироваться; вывод компилятора должен
#                       содержать каждую строку «// expect: ...», а если есть
#                       .err — совпасть с ним целиком; ключи компилятора — из
#                       «// flags: ...»; с --json (нужен python3) — правильный
#                       JSON с теми же местами и сообщениями;
#   tests/api/*.kh    — блоки test (khc test); вывод сравнивается с .out, и
#                       ещё раз — с проверками сборщика (KHRIP_GC_VERIFY=1:
#                       граф и куча store после загрузки и каждого теста);
#   tests/locks/*.kh  — какие маршруты берут store на чтение (khc check --locks);
#   tests/sqlcheck/   — правильный SQL: khc check без базы не находит ошибок;
#   tests/chcheck/    — то же для ch "..." и таблиц ClickHouse (PostgreSQL их
#                       не подтверждает, поэтому отдельно от tests/sqlcheck);
#   khc check --all-lib — вся библиотека (и не вызванные функции) и исходники
#                       компилятора (--system) проходят проверки системного кода;
#   регулярные выражения — проверка шаблонов при компиляции отвечает на наборе
#                       tests/run/regex_grammar.kh то же, что разбор библиотеки;
#                       tests/run/regex_go.kh — ответы Go regexp (если есть go,
#                       tools/regex_go.go -check сверяет его с генератором);
#   docs/tutorial/    — примеры учебника выполняются, их тесты проходят;
#   tests/http.sh     — HTTP-сервер на Khrip отвечает правильно;
#   tests/coro.sh     — запросы, которые ждут (sleep, fetch), не держат поток;
#   tests/tls.sh      — свой TLS 1.3: криптография, сертификаты, рукопожатия;
#   tests/pg.sh       — клиент PostgreSQL на временном сервере;
#   tests/mongo.sh, tests/clickhouse.sh, tests/databases/runtime.sh —
#                       бинарные кодеки и драйверы; реальные серверы задаются
#                       MONGODB_URI / CLICKHOUSE_URL (CLICKHOUSE_DATABASE —
#                       база тестов, по умолчанию khrip_test), mongod с TLS
#                       запускается в docker; пропуски печатаются строками SKIP;
#   tests/weather.sh  — погодный бэкенд: fetch, every, сохранение store;
#   eval/solutions/*/khrip — решения задач проверки проходят eval/run.sh.
# Компилятор берётся из $KHC (по умолчанию build/khc). С KHRIP_GC_VERIFY=1 в
# окружении проверки сборщика идут во всех программах набора (tests/api без
# них — только первый проход); с KHRIP_GC_VERIFY=fast — те же проверки, но
# выделение из store идёт и быстрым путём.
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
	build_env=$(sed -n 's|^// build-env: *||p' "$src" | head -1)
	# shellcheck disable=SC2086
	if ! env $build_env "$KHC" -o "$tmp/$name" "$src" >"$tmp/$name.err" 2>&1; then
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

mkdir -p "$tmp/json"
for src in tests/errors/*.kh; do
	flags=$(sed -n 's|^// flags: *||p' "$src" | head -1)
	# shellcheck disable=SC2086
	if "$KHC" check $flags "$src" >"$tmp/err.txt" 2>&1; then
		failed "$src" "скомпилировалось, а должна быть ошибка"
		continue
	fi
	# обычный вывод — для сверки с --json ниже
	[[ "$flags" != *--json* ]] && cp "$tmp/err.txt" "$tmp/json/$(basename "$src" .kh).text"
	ok=1
	while IFS= read -r want; do
		if ! grep -qF -- "$want" "$tmp/err.txt"; then
			failed "$src" "ожидалось «$want», получено:"$'\n'"$(cat "$tmp/err.txt")"
			ok=0
			break
		fi
	done < <(sed -n 's|^// expect: *||p' "$src")
	if [[ $ok -eq 1 && -f "${src%.kh}.err" ]] && ! diff -u "${src%.kh}.err" "$tmp/err.txt" >"$tmp/err.diff"; then
		failed "$src" "вывод отличается от ${src%.kh}.err"
		cat "$tmp/err.diff"
		ok=0
	fi
	[[ $ok -eq 1 ]] && pass=$((pass + 1))
done

# Ошибки в JSON (khc check --json): правильный JSON в UTF-8, какие бы байты ни
# были в исходнике и в пути, и те же места (столбец — номер символа) и
# сообщения, что в обычном выводе. Все tests/errors и файл с кавычкой, \,
# табуляцией и неправильным байтом в имени, а в тексте — с неправильным байтом,
# управляющим символом и кириллицей.
if command -v python3 >/dev/null; then
	odd="$tmp/json/"$'q"u\\o\tte\xff'".kh"
	printf 'fn main() {\n    let s = "мир\xff"; let x: int = "a"\n    let t = 1\x01\n    let имя = 2\n}\n' >"$odd"
	n=0
	for src in tests/errors/*.kh "$odd"; do
		flags=$(sed -n 's|^// flags: *||p' "$src" | head -1)
		# shellcheck disable=SC2086
		"$KHC" check $flags --json "$src" >"$tmp/json/$n.json" 2>&1
		text="$tmp/json/$(basename "$src" .kh).text"
		if [[ -f "$text" ]]; then
			mv "$text" "$tmp/json/$n.txt"
		else
			# shellcheck disable=SC2086
			"$KHC" check ${flags//--json/} "$src" >"$tmp/json/$n.txt" 2>&1
		fi
		printf '%s\n' "$src" >"$tmp/json/$n.src"
		n=$((n + 1))
	done
	if python3 -I - "$tmp/json" "$n" >"$tmp/json.txt" 2>&1 <<'PY'; then
import json, re, sys
d, n = sys.argv[1], int(sys.argv[2])
bad = 0
for i in range(n):
    src = open(f"{d}/{i}.src", "rb").read().decode("utf-8", "replace").strip()
    try:
        items = json.loads(open(f"{d}/{i}.json", "rb").read().decode("utf-8"))
        assert isinstance(items, list) and items, "an empty list"
        got = [(e["file"], e["line"], e["col"], e["message"], e["hint"]) for e in items]
    except Exception as e:
        print(f"{src}: not valid --json: {e}")
        bad += 1
        continue
    text = open(f"{d}/{i}.txt", "rb").read().decode("utf-8", "replace")
    want = [(f, int(l), int(c), m) for f, l, c, m in re.findall(r"^(.*):(\d+):(\d+): error: (.*)$", text, re.M)]
    if [g[:4] for g in got] != want:
        print(f"{src}: --json differs from the text output:\n  {got}\n  {want}")
        bad += 1
sys.exit(1 if bad else 0)
PY
		pass=$((pass + 1))
	else
		failed "khc check --json" "$(cat "$tmp/json.txt")"
	fi
fi

for src in tests/api/*.kh; do
	name=$(basename "$src" .kh)
	env -u KHRIP_GC_VERIFY "$KHC" test "$src" >"$tmp/$name.out" 2>&1
	if ! diff -u "tests/api/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
		failed "$src" "вывод тестов отличается от ожидаемого"
		cat "$tmp/$name.diff"
		continue
	fi
	pass=$((pass + 1))
done

# KHRIP_GC_VERIFY=1 (или fast, если набор идёт с ним): после загрузки store и
# после каждого теста каждый указатель его графа — в STORE или DATA, на начало
# выделенного объекта, а каждое поле-ссылка — с битом PTRB, и куча согласована
# (lib/gc_verify.kh); вывод тестов тот же, плюс строка проверки после загрузки.
verify=${KHRIP_GC_VERIFY:-1}
for src in tests/api/*.kh; do
	name=$(basename "$src" .kh)
	KHRIP_GC_VERIFY=$verify "$KHC" test "$src" >"$tmp/$name.vout" 2>&1
	if [[ $(grep -c '^khrip: gc verify (boot): [0-9]* roots, [0-9]* objects in STORE, every pointer in STORE or DATA$' "$tmp/$name.vout") != 1 ]]; then
		failed "$src (KHRIP_GC_VERIFY=$verify)" "нет строки проверки графа после загрузки:"$'\n'"$(cat "$tmp/$name.vout")"
		continue
	fi
	if ! grep -v '^khrip: gc verify (boot): ' "$tmp/$name.vout" | diff -u "tests/api/$name.out" - >"$tmp/$name.diff"; then
		failed "$src (KHRIP_GC_VERIFY=$verify)" "вывод тестов отличается от ожидаемого"
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
# с API (crud.kh; с проверками сборщика и без) и без него — вместе с исходниками
# компилятора в режиме --system.
if env -u KHRIP_GC_VERIFY "$KHC" check --all-lib tests/api/crud.kh >"$tmp/alllib.txt" 2>&1; then
	pass=$((pass + 1))
else
	failed "khc check --all-lib tests/api/crud.kh" "$(cat "$tmp/alllib.txt")"
fi
# с проверками сборщика (lib/gc_verify.kh вместо заглушек lib/gc_noverify.kh)
if KHRIP_GC_VERIFY=1 "$KHC" check --all-lib tests/api/crud.kh >"$tmp/alllib.txt" 2>&1; then
	pass=$((pass + 1))
else
	failed "KHRIP_GC_VERIFY=1 khc check --all-lib tests/api/crud.kh" "$(cat "$tmp/alllib.txt")"
fi
if "$KHC" check --system --all-lib src/*.kh >"$tmp/alllib.txt" 2>&1; then
	pass=$((pass + 1))
else
	failed "khc check --system --all-lib src/*.kh" "$(cat "$tmp/alllib.txt")"
fi

# Раскладка контекста потока: все слова CTX_* объявлены в одной таблице
# lib/core.kh, смещения не повторяются и не заходят в буферы системных
# вызовов (слова 192–223 и 232–239).
ctx_words=$(sed -n 's/^const CTX_[A-Z_]* = \([0-9][0-9]*\)$/\1/p' lib/core.kh)
ctx_other=$(grep -l '^const CTX_' lib/*.kh | grep -v '^lib/core.kh$')
ctx_dup=$(sort -n <<<"$ctx_words" | uniq -d)
ctx_scratch=$(awk '($1 >= 192 && $1 < 224) || ($1 >= 232 && $1 < 240)' <<<"$ctx_words")
if [[ -z "$ctx_other$ctx_dup$ctx_scratch" ]]; then
	pass=$((pass + 1))
else
	failed "раскладка ctx" "вне lib/core.kh: $ctx_other; повторы: $ctx_dup; в буферах системных вызовов: $ctx_scratch"
fi

# Шаблоны регулярных выражений: проверка при компиляции (src/rx.kh) отвечает
# на наборе tests/run/regex_grammar.kh то же, что разбор библиотеки
# (tests/run/regex_grammar.out): шаблоны — литералами в s.matches, по 50 на
# программу (khc сообщает не больше 100 ошибок), по одному на строку.
sed -n '/^        \/\/ набор$/,/^        \/\/ конец набора$/p' tests/run/regex_grammar.kh |
	sed '1d;$d' | sed 's/^ *//; s/,$//' >"$tmp/rx_pats.txt"
rx_n=$(wc -l <"$tmp/rx_pats.txt")
: >"$tmp/rx_check.out"
rx_ok=1
for ((rx_c = 0; rx_c * 50 < rx_n; rx_c++)); do
	{
		printf 'fn main() {\n    let s = "x"\n'
		sed -n "$((rx_c * 50 + 1)),$((rx_c * 50 + 50))p" "$tmp/rx_pats.txt" | sed 's/^/    print(s.matches(/; s/$/))/'
		printf '}\n'
	} >"$tmp/rx_$rx_c.kh"
	"$KHC" check "$tmp/rx_$rx_c.kh" >"$tmp/rx_$rx_c.txt" 2>&1
	if grep ': error: ' "$tmp/rx_$rx_c.txt" | grep -vq ': error: invalid pattern: '; then
		failed "регулярные выражения при компиляции" "$(cat "$tmp/rx_$rx_c.txt")"
		rx_ok=0
	fi
	rx_m=$(sed -n "$((rx_c * 50 + 1)),$((rx_c * 50 + 50))p" "$tmp/rx_pats.txt" | wc -l)
	for ((rx_j = 0; rx_j < rx_m; rx_j++)); do
		rx_e=$(sed -n "s|^.*:$((rx_j + 3)):[0-9]*: error: invalid pattern: ||p" "$tmp/rx_$rx_c.txt")
		echo "$((rx_c * 50 + rx_j)): ${rx_e:-ok}" >>"$tmp/rx_check.out"
	done
done
if ((rx_ok)); then
	if diff -u tests/run/regex_grammar.out "$tmp/rx_check.out" >"$tmp/rx_check.diff"; then
		pass=$((pass + 1))
	else
		failed "регулярные выражения: проверка при компиляции и разбор библиотеки расходятся" "$(cat "$tmp/rx_check.diff")"
	fi
fi
# Сверка с Go regexp (если есть go): tests/run/regex_go.kh и его .out — ровно
# то, что пишет tools/regex_go.go сейчас, а правильные шаблоны набора
# regex_grammar Go тоже принимает.
if command -v go >/dev/null; then
	if go run tools/regex_go.go -check >"$tmp/regex_go.txt" 2>&1; then
		pass=$((pass + 1))
	else
		failed "tools/regex_go.go -check" "$(cat "$tmp/regex_go.txt")"
	fi
fi

# Программа без store не несёт кода кучи store (lib/nostore.kh вместо
# lib/gc.kh) — и с драйвером и слоем ClickHouse (ch "...", таблицы,
# маршруты: ch_lex.kh, chdb/api.kh), а без KHRIP_GC_VERIFY при сборке
# программа со store — кода проверок сборщика (lib/gc_noverify.kh вместо
# lib/gc_verify.kh).
for src in tests/run/arith.kh tests/run/net_sigpipe.kh tests/run/ch_lex.kh tests/chdb/api.kh; do
	env -u KHRIP_GC_VERIFY "$KHC" --sizes -o "$tmp/nostore" "$src" >"$tmp/nostore.txt" 2>&1
	if grep -E ' (__salloc|__pmode_|__gc_|__span_|__ph_|__store_mut)' "$tmp/nostore.txt" >"$tmp/nostore.bad"; then
		failed "$src" "код store в программе без store:"$'\n'"$(cat "$tmp/nostore.bad")"
	else
		pass=$((pass + 1))
	fi
done
env -u KHRIP_GC_VERIFY "$KHC" --sizes -o "$tmp/store" tests/api/crud.kh >"$tmp/store.txt" 2>&1
if grep -E ' (__gcv_|__gc_verify_graph|__gc_verify_heap|__ph_check|__ph_selftest)' "$tmp/store.txt" >"$tmp/store.bad"; then
	failed "tests/api/crud.kh" "проверки сборщика без KHRIP_GC_VERIFY:"$'\n'"$(cat "$tmp/store.bad")"
else
	pass=$((pass + 1))
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
for src in tests/sqlcheck/*.kh tests/chcheck/*.kh; do
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

# Библиотеки драйверов — только программам, которые пользуются их именами:
# в сервере со своими type Mongo, fn ch_query и store ch_total нет ни одной
# функции драйверов и TLS, в CLI-программе — и библиотеки API.
if "$KHC" --sizes -o "$tmp/own_api" tests/api/own_driver_names.kh >"$tmp/own_api.sizes" 2>&1 &&
	"$KHC" --sizes -o "$tmp/own_cli" tests/run/own_driver_names.kh >"$tmp/own_cli.sizes" 2>&1 &&
	! grep -qE ' __(bson|mongo|ch|dh|tls)_' "$tmp/own_api.sizes" "$tmp/own_cli.sizes" &&
	! grep -qE ' __(json|reply|dispatch)' "$tmp/own_cli.sizes"; then
	pass=$((pass + 1))
else
	failed "драйверы по точным именам" "в программе без драйверов есть их код:"$'\n'"$(grep -E ' __(bson|mongo|ch|dh|tls|json|reply|dispatch)' "$tmp/own_api.sizes" "$tmp/own_cli.sizes" | head)"
fi

# Программа без имён, похожих на имена драйверов (свои Mongo и ch_query тоже
# не в счёт), не читает тексты их библиотек: здесь вместо них именованные
# каналы, открытие которых ждало бы писателя, — компиляция не закончилась бы.
mkdir -p "$tmp/fifolib"
cp lib/*.kh "$tmp/fifolib/"
for f in bson mongo clickhouse; do
	rm -f "$tmp/fifolib/$f.kh"
	mkfifo "$tmp/fifolib/$f.kh"
done
fifo_ok=1
for src in tests/run/own_driver_names.kh tests/api/own_driver_names.kh tests/api/crud.kh; do
	if ! KHRIP_LIB="$tmp/fifolib" timeout 20 "$KHC" -o "$tmp/fifo_prog" "$src" >"$tmp/fifo.txt" 2>&1; then
		fifo_ok=0
		failed "$src без драйверов" "читает библиотеки драйверов (или не скомпилировалось): $(cat "$tmp/fifo.txt")"
	fi
done
[[ $fifo_ok -eq 1 ]] && pass=$((pass + 1))
# Тексты библиотек читаются только при имени, похожем на имя драйвера
# (driver_like): khc check --all-lib находит имя библиотеки драйвера не по образцу.
mkdir -p "$tmp/namelib"
cp lib/*.kh "$tmp/namelib/"
printf '\nfn sloppy_helper() -> int {\n    return 1\n}\n' >>"$tmp/namelib/bson.kh"
KHRIP_LIB="$tmp/namelib" "$KHC" check --all-lib tests/api/crud.kh >"$tmp/names.txt" 2>&1
if grep -q "'sloppy_helper' does not look like a driver name" "$tmp/names.txt" && grep -q "^1 error" "$tmp/names.txt"; then
	pass=$((pass + 1))
else
	failed "имена библиотек драйверов" "$(cat "$tmp/names.txt")"
fi

# tests/databases/run.sh работает и в macOS, где /bin/bash — 3.2: там пустой
# массив в "${a[@]}" при set -u — «unbound variable» (раскрывать как
# ${a[@]+"${a[@]}"}), а mapfile, declare -A и ${x,,} нет вовсе.
if ! grep -nE '(^|[^+])"\$\{[A-Za-z_]+\[[@*]\]\}"|mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)\}' tests/databases/run.sh | grep -v '^[0-9]*:[[:space:]]*#' >"$tmp/bash32.txt"; then
	pass=$((pass + 1))
else
	failed "tests/databases/run.sh: bash 3.2" "$(cat "$tmp/bash32.txt")"
fi

# Конец запроса (__db_end, src/api.kh gen_db): очистки без сети — MongoDB,
# ClickHouse, TLS — раньше отката PostgreSQL, который ждёт сервер до 5 с; хук
# TLS есть и в программе только с fetch. Хуки маленькие и встраиваются, в
# --sizes их не видно, поэтому проверяется текст генератора.
db_end=$(sed -n '/^fn gen_db(/,/^}/p' src/api.kh | grep -o '__[a-z_]*_\(request_end\|request_cleanup\|pending_cleanup\)' | tr '\n' ' ')
if [[ "$db_end" == "__mongo_request_end __ch_request_cleanup __tls_pending_cleanup __pg_request_end " ]] &&
	sed -n '/^fn gen_db(/,/^}/p' src/api.kh | grep -B1 '__tls_pending_cleanup' | grep -q 'uses_fetch()'; then
	pass=$((pass + 1))
else
	failed "очистки конца запроса" "порядок в gen_db: $db_end; хук TLS нужен и программе только с fetch"
fi

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

# Отдельные процессы: сценарии драйверов владеют своими временными файлами
# и trap. Без адресов БД выполняются проверки кодеков и повреждённого протокола;
# что пропущено (настоящие серверы, контейнер с TLS), видно по строкам SKIP.
# Общий сценарий обоих драйверов в одном сервере (tests/databases/runtime.sh)
# — когда заданы оба адреса.
for driver in mongo clickhouse databases/runtime chdb; do
	if ! command -v python3 >/dev/null; then
		echo "SKIP $driver: нет python3 для mock-серверов"
		continue
	fi
	if KHC="$KHC" bash "tests/$driver.sh" >"$tmp/driver.log" 2>&1; then
		pass=$((pass + 1))
		grep '^SKIP' "$tmp/driver.log"
	else
		failed "$driver" "$(cat "$tmp/driver.log")"
	fi
done
if "$KHC" check tests/databases/codec_tx.kh >"$tmp/codec-tx.log" 2>&1; then
	pass=$((pass + 1))
else
	failed "codecs inside tx" "$(cat "$tmp/codec-tx.log")"
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
