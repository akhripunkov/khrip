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
#   tests/gc.sh       — сборщик store: запросы держат значения через ожидания,
#                       пока писатели их заменяют, а сборщик собирает;
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
# выделение из store идёт и быстрым путём. С KHRIP_GC_STRESS=1 сборка идёт
# очень часто (каждые 64 КБ выделений в store) и с проверками во всех
# программах набора, кроме первого прохода tests/api; tests/api/gc_*.kh и без
# неё проходят третий раз — с KHRIP_GC_STRESS=1.
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
	env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS "$KHC" test "$src" >"$tmp/$name.out" 2>&1
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

# Тесты сборщика (tests/api/gc_*.kh) — ещё и с KHRIP_GC_STRESS=1 (если набор
# идёт без неё): сборка в каждой точке сборки теста и каждые 64 КБ выделений,
# с проверками; вывод тот же.
if [[ "${KHRIP_GC_STRESS:-}" != 1 ]]; then
	for src in tests/api/gc_*.kh; do
		name=$(basename "$src" .kh)
		KHRIP_GC_STRESS=1 "$KHC" test "$src" 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/$name.sout"
		if ! diff -u "tests/api/$name.out" "$tmp/$name.sout" >"$tmp/$name.diff"; then
			failed "$src (KHRIP_GC_STRESS=1)" "вывод тестов отличается от ожидаемого"
			cat "$tmp/$name.diff"
			continue
		fi
		pass=$((pass + 1))
	done
fi

# Проверка конца разметки сама по себе (lib/gc_verify.kh: снимок начала
# сборки независим от разметки): на копиях библиотеки, где разметка теряет
# слова записей, кусок арены или барьер pop, tests/api/gc_snapshot.kh с
# KHRIP_GC_VERIFY=1 останавливается на ней, хотя потерянный объект больше ни
# от чего не достижим; и с KHRIP_GC_FAULT=hbuf (системе не хватило памяти на
# hbuf передачи арены: контекст размечает её сам) и hbuf2 (hbuf не растёт
# после первого куска: часть арены уже в нём) — тот же вывод, как и у оракула
# tests/api/gc_satb_oracle.kh с KHRIP_GC_FAULT=hbuf.
snap_ok=1
for cut in pins arena pop; do
	rm -rf "${tmp:?}/snaplib"
	mkdir -p "$tmp/snaplib"
	cp lib/*.kh "$tmp/snaplib/"
	if ! python3 - "$tmp/snaplib" "$cut" <<'PY'
import sys
d, m = sys.argv[1], sys.argv[2]
cuts = {
    "pins": ("gc.kh", "            __gc_pins_add(rec.buf, rec.len)\n", ""),
    "arena": ("gc.kh", "                var p = from\n                var k = 0\n", "                var p = from + 4096\n                var k = 0\n"),
    "pop": ("core.kh", "        __gc_shade(v)\n", ""),
}
f, old, new = cuts[m]
s = open(f"{d}/{f}").read()
if s.count(old) != 1:
    sys.exit(1)
open(f"{d}/{f}", "w").write(s.replace(old, new))
PY
	then
		snap_ok=0
		failed "проверка конца разметки ($cut)" "место для подложенной ошибки не найдено в lib/"
		continue
	fi
	KHRIP_LIB="$tmp/snaplib" KHRIP_GC_VERIFY=1 "$KHC" test tests/api/gc_snapshot.kh >"$tmp/snap.txt" 2>&1
	if ! grep -q '^khrip: gc verify: an object at 0x[0-9a-f]* reachable at the start of the cycle is not marked' "$tmp/snap.txt"; then
		snap_ok=0
		failed "проверка конца разметки ($cut)" "не нашла потерянный объект:"$'\n'"$(cat "$tmp/snap.txt")"
	fi
done
for fault in "gc_snapshot hbuf" "gc_snapshot hbuf2" "gc_satb_oracle hbuf"; do
	read -r name mode <<<"$fault"
	KHRIP_GC_VERIFY=1 KHRIP_GC_FAULT=$mode "$KHC" test "tests/api/$name.kh" 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/snap.txt"
	if ! diff -u "tests/api/$name.out" "$tmp/snap.txt" >"$tmp/snap.diff"; then
		snap_ok=0
		failed "tests/api/$name.kh (KHRIP_GC_FAULT=$mode)" "$(cat "$tmp/snap.diff")"
	fi
done
[[ $snap_ok -eq 1 ]] && pass=$((pass + 1))

# Темп и уборка кусками (шаг 6b) сами по себе: tests/api/gc_pace.kh с
# KHRIP_GC_LIMIT_MB=3 (первый тест сверяет цель с ним) — тот же вывод; на
# копиях библиотеки без сброса текущих спанов в конце разметки, без номера
# уборки у нового спана, без доуборки в начале сборки (tests/api/gc_sweep.kh),
# с запасом 100 % вместо 50 % по умолчанию, без мягкого предела, без помощи
# писателя и без помощи по счёту
# (tests/api/gc_pace.kh), с записью, которая не копирует место сохранения
# регистров __pin_publish (tests/api/gc_regs.kh: значение только в r14 —
# если кодогенерация уведёт его оттуда, тест перестанет что-то проверять, и
# это заметно здесь), тесты падают.
pace_ok=1
KHRIP_GC_LIMIT_MB=3 "$KHC" test tests/api/gc_pace.kh 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/pace.txt"
if ! diff -u tests/api/gc_pace.out "$tmp/pace.txt" >"$tmp/pace.diff"; then
	pace_ok=0
	failed "tests/api/gc_pace.kh (KHRIP_GC_LIMIT_MB=3)" "$(cat "$tmp/pace.diff")"
fi
for cut in "gc_sweep cur" "gc_sweep newgen" "gc_sweep finish" "gc_pace pct" "gc_pace soft" "gc_pace assist" "gc_pace credit" "gc_regs savearea"; do
	read -r name mut <<<"$cut"
	rm -rf "${tmp:?}/pacelib"
	mkdir -p "$tmp/pacelib"
	cp lib/*.kh "$tmp/pacelib/"
	if ! python3 - "$tmp/pacelib" "$mut" <<'PY'
import sys
d, m = sys.argv[1], sys.argv[2]
cuts = {
    "cur": ("        store64(__gc_cur + j * 8, __gc_none)\n        store64(__gc_partial + j * 16, 0)\n", "        store64(__gc_partial + j * 16, 0)\n"),
    "newgen": ("    store64(s + S_SWEEPGEN, __gc_sweepgen)\n    store64(s + S_MAGIC, ((", "    store64(s + S_SWEEPGEN, __gc_sweepgen - 1)\n    store64(s + S_MAGIC, (("),
    "finish": ("    if __gc_phase == GC_PH_SWEEP {\n        __gc_sweep_finish(why)\n    }\n", ""),
    "pct": ("    __gc_pct = 50\n", "    __gc_pct = 100\n"),
    "savearea": ("    let sp = load64(rec.regs + 16) - __save_area()\n", "    let sp = load64(rec.regs + 16) + 16\n"),
    "soft": ("        if goal > __gc_soft {\n            goal = __gc_soft\n        }\n", ""),
    "assist": ("        } else if __gc_phase == GC_PH_MARK && __heap_live > __gc_cgoal {\n            __gc_assist()\n        }\n", "        }\n"),
    "credit": ("        if debt <= 0 || rem <= 0 {\n            return\n        }\n", "        if true {\n            return\n        }\n"),
}
old, new = cuts[m]
s = open(f"{d}/gc.kh").read()
if s.count(old) != 1:
    sys.exit(1)
open(f"{d}/gc.kh", "w").write(s.replace(old, new))
PY
	then
		pace_ok=0
		failed "темп и уборка кусками ($mut)" "место для подложенной ошибки не найдено в lib/gc.kh"
		continue
	fi
	# без механизма тест может и упасть (освобождённый живой объект): строку
	# оболочки о сигнале — мимо вывода набора
	{ KHRIP_LIB="$tmp/pacelib" env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS "$KHC" test "tests/api/$name.kh" >"$tmp/pace.txt" 2>&1; } 2>/dev/null
	if diff -q "tests/api/$name.out" "$tmp/pace.txt" >/dev/null; then
		pace_ok=0
		failed "темп и уборка кусками ($mut)" "tests/api/$name.kh проходит и без проверяемого механизма"
	fi
done
[[ $pace_ok -eq 1 ]] && pass=$((pass + 1))

# Рост словаря по частям (этап памяти, часть 2) сам по себе: на копиях
# библиотеки без серения старых массивов ключей, значений и признаков, старой
# таблицы и G при переключении, без серения G в clear, без битов PTRB и без
# обнуления новой памяти, без повторения замены и удаления перенесённой записи
# в новых массивах (и по тому же номеру, если таблица остаётся старой), без
# подъёма порога сборки на время роста, без его возврата, без предела подъёма
# (середина между целью и жёстким пределом) и без порога в восьмую часть кучи tests/api/gc_mapgrow.kh с
# KHRIP_GC_VERIFY=1 падает (серения
# старой таблицы, признаков и G находит только проверка конца разметки: эти
# объекты уже мусор, но были достижимы в начале сборки; без серения значений
# тест падает и без проверок — запись держат только чёрные новые массивы).
grow_ok=1
for cut in keys vals alive slots gend gclear ptrb zero set remove keepset hold release goal share; do
	rm -rf "${tmp:?}/growlib"
	mkdir -p "$tmp/growlib"
	cp lib/*.kh "$tmp/growlib/"
	if ! python3 - "$tmp/growlib" "$cut" <<'PY'
import sys
d, m = sys.argv[1], sys.argv[2]
cuts = {
    "keys": ("    __gc_old_at(m, m)\n    __gc_old_at(m, m + 16)\n", "    __gc_old_at(m, m + 16)\n"),
    "vals": ("    __gc_old_at(m, m + 16)\n    __gc_old_at(m, m + 24)\n", "    __gc_old_at(m, m + 24)\n"),
    "alive": ("    __gc_old_at(m, m + 24)\n    store64(m, load64(g))\n", "    store64(m, load64(g))\n"),
    "slots": ("    if load64(g + 24) != 0 {\n        __gc_old_slots(m)\n", "    if load64(g + 24) != 0 {\n"),
    "gend": ("        store32(m + 40, load64(g + 32))\n    }\n    __gc_old_at(m, m + 56)\n", "        store32(m + 40, load64(g + 32))\n    }\n"),
    "gclear": ("        // рост бросается (§7.5: G уходит из заголовка)\n        __gc_old_at(m, m + 56)\n", "        // рост бросается (§7.5: G уходит из заголовка)\n"),
    "ptrb": ("            __gc_ptrb_on(p + off, n)\n", ""),
    "zero": ("            __memset(p + off, 0, n)\n", ""),
    "set": ("    if load64(m + 56) != 0 {\n        __map_grow_set(m, k, idx, v)\n    }\n", ""),
    "remove": ("    if load64(m + 56) != 0 {\n        __map_grow_remove(m, k, idx)\n    }\n", ""),
    "keepset": ("        // таблица остаётся старой: номер записи тот же\n        return idx\n", "        return -1\n"),
    "hold": ("        __gc_grow_hold(total, g)\n", ""),
    "release": ("    store64(m + 56, 0)\n    __gc_grow_done(load64(g + 96), load64(g + 80))\n}\n", "    store64(m + 56, 0)\n}\n"),
    "goal": ("    if __gc_trigger + up > top {\n        up = top - __gc_trigger\n    }\n", "", "gc.kh"),
    "share": (" || n < __heap_live / 8 {\n", " {\n", "gc.kh"),
}
old, new = cuts[m][0], cuts[m][1]
f = cuts[m][2] if len(cuts[m]) > 2 else "core.kh"
s = open(f"{d}/{f}").read()
if s.count(old) != 1:
    sys.exit(1)
open(f"{d}/{f}", "w").write(s.replace(old, new))
PY
	then
		grow_ok=0
		failed "рост словаря ($cut)" "место для подложенной ошибки не найдено в lib/core.kh или lib/gc.kh"
		continue
	fi
	# без механизма тест может и упасть (освобождённый живой объект): строку
	# оболочки о сигнале — мимо вывода набора
	{ KHRIP_LIB="$tmp/growlib" KHRIP_GC_VERIFY=1 env -u KHRIP_GC_STRESS timeout 120 "$KHC" test tests/api/gc_mapgrow.kh 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/grow.txt"; } 2>/dev/null
	if diff -q tests/api/gc_mapgrow.out "$tmp/grow.txt" >/dev/null; then
		grow_ok=0
		failed "рост словаря ($cut)" "tests/api/gc_mapgrow.kh проходит и без проверяемого механизма"
	fi
done
[[ $grow_ok -eq 1 ]] && pass=$((pass + 1))

# Представление данных store (этап памяти, часть 3) само по себе: на копиях
# библиотеки с подложенной ошибкой тест пункта падает — без проверок (plain)
# или с KHRIP_GC_VERIFY=1 (verify), как указано у каждой мутации:
#   keyshare — ключ словаря не берётся из поля значения (gc_keys, plain);
#   keyreplace — ключ копируется и при замене значения (gc_keys, plain);
#   listptrb — ёмкость списка — весь слот, а биты PTRB — только на
#              запрошенные байты (gc_lists, verify: ссылка без бита PTRB);
#   listcap — ёмкость копии снова от 4 элементов (gc_lists, plain);
#   mapvkind — массив значений-ссылок словаря без битов PTRB (gc_maps,
#              verify: ссылка без бита PTRB);
#   mapkkind — то же у массива строковых ключей (gc_maps, verify);
#   mapalive — признак «жива» не снимается при удалении (gc_maps, plain);
#   mapbytes — копия словаря кладёт значения bool словом (gc_maps, plain);
#   listbool — массив [bool] в store с начала слота: размер элемента по адресу
#              не узнать (gc_lists, plain);
#   listroom — ёмкость списка store — весь слот, без сдвига массива [bool]
#              (gc_lists, verify);
#   listgrow — рост списка store без вида старого массива: новый массив
#              ссылок без PTRB (gc_lists, verify);
#   listvacate — серение ушедших элементов списка store по слову 24 старого
#              заголовка (gc_satb, verify).
mem3_ok=1
while read -r cut test mode; do
	[[ -z $cut ]] && continue
	rm -rf "${tmp:?}/mem3lib"
	mkdir -p "$tmp/mem3lib"
	cp lib/*.kh "$tmp/mem3lib/"
	if ! python3 - "$tmp/mem3lib" "$cut" <<'PY'
import sys
d, m = sys.argv[1], sys.argv[2]
cuts = {
    "keyshare": ("    var key = __map_key_share(k, v, vd)\n", "    var key = 0\n", "api.kh"),
    "keyreplace": ("    __store_mut(m)\n    let idx = __map_find(m, k)\n    if idx >= 0 {\n        __map_update(m, k, idx, v)\n        return\n    }\n    var key = __map_key_share(k, v, vd)\n", "    __store_mut(m)\n    let k2 = __persist_copy(k, kd)\n    let idx = __map_find(m, k)\n    if idx >= 0 {\n        __map_update(m, k2, idx, v)\n        return\n    }\n    var key = __map_key_share(k, v, vd)\n", "api.kh"),
    "listptrb": ("    return __salloc(__salloc_size(n), kind, 0)\n}\n", "    return __salloc(n, kind, 0)\n}\n", "core.kh"),
    "listcap": ("    var n = cap * 8\n    if n < 16 {\n        n = 16\n    }\n", "    var n = cap * 8\n    if n < 32 {\n        n = 32\n    }\n", "core.kh"),
    "mapvkind": ("fn __map_vkind(flags: int) -> int {\n    if (flags & MAP_REFS) != 0 {\n        return K_PTRS\n", "fn __map_vkind(flags: int) -> int {\n    if false {\n        return K_PTRS\n", "core.kh"),
    "mapkkind": ("fn __map_kkind(flags: int) -> int {\n    if (flags & MAP_STR) != 0 {\n        return K_PTRS\n", "fn __map_kkind(flags: int) -> int {\n    if false {\n        return K_PTRS\n", "core.kh"),
    "mapalive": ("    store8(load64(m + 24) + idx, 0)\n    store64(m + 8, load64(m + 8) - 1)\n", "    store64(m + 8, load64(m + 8) - 1)\n", "core.kh"),
    "mapbytes": ("                __map_val_put(m, vals, w, sv)\n", "                store64(vals + w * 8, sv)\n", "api.kh"),
    "listbool": ("        return __salloc(__salloc_size(cap + 8), kind, 0) + 8\n", "        return __salloc(__salloc_size(cap + 8), kind, 0)\n", "core.kh"),
    "listroom": ("    return slot + size - p\n", "    return size\n", "gc.kh"),
    "listgrow": ("fn __salloc_list(h: int, cap: int, es: int) -> int {\n    let kind = __gc_kind_of(load64(h))\n", "fn __salloc_list(h: int, cap: int, es: int) -> int {\n    let kind = K_NOSCAN\n", "gc.kh"),
    "listvacate": ("    if __gc_marking != 0 && __list_es(h) == 8 {\n", "    if __gc_marking != 0 && load64(h + 24) == 8 {\n", "gc.kh"),
}
old, new, f = cuts[m]
s = open(f"{d}/{f}").read()
if s.count(old) != 1:
    sys.exit(1)
open(f"{d}/{f}", "w").write(s.replace(old, new))
PY
	then
		mem3_ok=0
		failed "представление store ($cut)" "место для подложенной ошибки не найдено в lib/"
		continue
	fi
	venv=(env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS)
	[[ $mode == verify ]] && venv=(env -u KHRIP_GC_STRESS KHRIP_GC_VERIFY=1)
	{ KHRIP_LIB="$tmp/mem3lib" "${venv[@]}" timeout 120 "$KHC" test "tests/api/$test.kh" 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/mem3.txt"; } 2>/dev/null
	if diff -q "tests/api/$test.out" "$tmp/mem3.txt" >/dev/null; then
		mem3_ok=0
		failed "представление store ($cut)" "tests/api/$test.kh проходит и без проверяемого механизма"
	fi
done <<'CUTS'
keyshare gc_keys plain
keyreplace gc_keys plain
listptrb gc_lists verify
listcap gc_lists plain
mapvkind gc_maps verify
mapkkind gc_maps verify
mapalive gc_maps plain
mapbytes gc_maps plain
listbool gc_lists plain
listroom gc_lists verify
listgrow gc_lists verify
listvacate gc_satb verify
CUTS
[[ $mem3_ok -eq 1 ]] && pass=$((pass + 1))

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
if env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS "$KHC" check --all-lib tests/api/crud.kh >"$tmp/alllib.txt" 2>&1; then
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

# Места отпускания блокировки store (docs/design/v0.13-store-gc.md §6.5–6.6):
# tests/store_windows.sh — посреди работы только __store_release_keep и только
# в проверенных местах, отпускание без записи — только в API блокировки. И
# проверка самой проверки: на копиях библиотеки с подложенным нарушением она
# должна упасть, а на безвредных строках и комментариях — пройти.
if win_out=$(bash tests/store_windows.sh .); then
	pass=$((pass + 1))
else
	failed "места отпускания store" "$win_out"
fi
# случай: ожидание (pass/fail), файл, функция для вставки внутрь ("" — новая
# функция в конце файла), текст
win_cases=(
	'fail|lib/rt.kh|__slot_take|    __store_unlock_raw()'
	'fail|lib/gc.kh||fn __plant() {\n    __store_unlock_raw()\n    sleep(10)\n    __store_lock()\n}'
	'fail|lib/pg.kh||fn __plant() {\n    __store_write_unlock(__store_rw)\n}'
	'fail|lib/mongo.kh||fn __plant() {\n    __store_unlock_gc()\n}'
	'fail|lib/mongo.kh||fn __plant() {\n    __store_unlock_marker()\n}'
	'fail|lib/rt.kh||fn __plant_unlock() {\n    __store_unlock_raw()\n}'
	'fail|lib/pg.kh||fn __plant() {\n    __mutex_unlock(__store_rw)\n}'
	'fail|lib/fetch.kh||fn __plant() {\n    let u = "http://x"; __store_release_keep()\n}'
	'fail|lib/fetch.kh||fn __plant(c: int) {\n    if c == \x27"\x27 { __store_release_keep() }\n}'
	'fail|lib/fetch.kh||fn __plant() {\n    print("{__store_unlock_raw()}")\n}'
	'pass|lib/fetch.kh||fn __plant() {\n    print("__store_release_keep( and __store_unlock_raw(")\n    // __store_unlock_raw()\n    let s = `\n__store_release_keep()\n`\n}'
)
win_ok=1
for c in "${win_cases[@]}"; do
	IFS='|' read -r want file fn text <<<"$c"
	rm -rf "$tmp/winlib"
	mkdir -p "$tmp/winlib"
	cp -r lib "$tmp/winlib/"
	if [[ -n "$fn" ]]; then
		awk -v f="$fn" -v t="$(printf '%b' "$text")" '{ print } index($0, "fn " f "(") == 1 { print t }' "$file" >"$tmp/winlib/$file"
	else
		printf '\n%b\n' "$text" >>"$tmp/winlib/$file"
	fi
	if bash tests/store_windows.sh "$tmp/winlib" >"$tmp/win.txt"; then got=pass; else got=fail; fi
	if [[ "$got" != "$want" ]]; then
		win_ok=0
		failed "проверка мест отпускания store" "ожидалось $want, вышло $got: $file ${fn:-(новая функция)}: $(printf '%b' "$text"); $(cat "$tmp/win.txt")"
	fi
done
[[ $win_ok -eq 1 ]] && pass=$((pass + 1))

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
# маршруты: ch_lex.kh, chdb/api.kh), а без KHRIP_GC_VERIFY и KHRIP_GC_LOG при
# сборке программа со store — кода проверок и журнала сборщика
# (lib/gc_noverify.kh вместо lib/gc_verify.kh, lib/gc_nolog.kh вместо
# lib/gc_log.kh).
for src in tests/run/arith.kh tests/run/net_sigpipe.kh tests/run/ch_lex.kh tests/chdb/api.kh; do
	env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS "$KHC" --sizes -o "$tmp/nostore" "$src" >"$tmp/nostore.txt" 2>&1
	if grep -E ' (__salloc|__pmode_|__gc_|__span_|__ph_|__store_mut)' "$tmp/nostore.txt" >"$tmp/nostore.bad"; then
		failed "$src" "код store в программе без store:"$'\n'"$(cat "$tmp/nostore.bad")"
	else
		pass=$((pass + 1))
	fi
done
env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS -u KHRIP_GC_LOG "$KHC" --sizes -o "$tmp/store" tests/api/crud.kh >"$tmp/store.txt" 2>&1
if grep -E ' (__gcv_|__gc_verify_graph|__gc_verify_heap|__ph_check|__ph_selftest|__gc_line|__gc_why)' "$tmp/store.txt" >"$tmp/store.bad"; then
	failed "tests/api/crud.kh" "проверки или журнал сборщика без KHRIP_GC_VERIFY и KHRIP_GC_LOG:"$'\n'"$(cat "$tmp/store.bad")"
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

if [[ -f tests/gc.sh ]] && command -v curl >/dev/null && command -v python3 >/dev/null; then
	# shellcheck source=tests/gc.sh
	source tests/gc.sh
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
