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
#   tests/rw_gen.py   — то же на сгенерированных маршрутах, которые меняют store
#                       через псевдонимы: ни одного read;
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
#   eval/solutions/*/khrip — решения задач проверки проходят eval/run.sh;
#   skill/khrip/      — скилл Khrip: ядро SKILL.md не больше 3000 токенов o200k,
#                       глава — не больше 900 (eval/tokens/count.mjs --raw; без
#                       node или gpt-tokenizer — строка SKIP); блоки кода
#                       компилируются, примеры глав работают на настоящих базах,
#                       ключевые правила сходятся с компилятором
#                       (tests/skill/check.py).
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
        got = [(e["file"], e["line"], e["col"], e["severity"], e["message"], e["hint"]) for e in items]
    except Exception as e:
        print(f"{src}: not valid --json: {e}")
        bad += 1
        continue
    text = open(f"{d}/{i}.txt", "rb").read().decode("utf-8", "replace")
    want = [(f, int(l), int(c), sev, m) for f, l, c, sev, m in re.findall(r"^(.*):(\d+):(\d+): (error|warning): (.*)$", text, re.M)]
    if [g[:5] for g in got] != want:
        print(f"{src}: --json differs from the text output:\n  {got}\n  {want}")
        bad += 1
sys.exit(1 if bad else 0)
PY
		pass=$((pass + 1))
	else
		failed "khc check --json" "$(cat "$tmp/json.txt")"
	fi
fi

# Предупреждение (W-A2: анонимный тип, записанный трижды) сборку не
# останавливает: khc check — код 0, одна строка «warning:» и итог «1 warning»,
# в --json — запись с "severity":"warning"; код программы с предупреждением
# тот же, что без него (встраивание не выключается: --sizes у main одинаков).
cat >"$tmp/warn2.kh" <<'KH'
fn a(p: { x: int }) -> int {
    return p.x
}
fn b(p: { x: int }) -> int {
    return p.x
}
fn add1(x: int) -> int {
    return x + 1
}
fn main() {
    print((add1(41) + a({ x: 1 }) + b({ x: 2 })).to_str())
}
KH
cp "$tmp/warn2.kh" "$tmp/warn3.kh"
cat >>"$tmp/warn3.kh" <<'KH'
fn c(p: { x: int }) -> int {
    return p.x
}
KH
w_ok=1
"$KHC" check "$tmp/warn3.kh" >"$tmp/warn.txt" 2>&1 || w_ok=0
[[ $(grep -c ': warning: the anonymous type { x: int } is written 3 times$' "$tmp/warn.txt") == 1 && $(tail -1 "$tmp/warn.txt") == "1 warning" ]] || w_ok=0
"$KHC" check --json "$tmp/warn3.kh" >"$tmp/warn.json" 2>&1 || w_ok=0
grep -q '"severity":"warning"}]$' "$tmp/warn.json" || w_ok=0
"$KHC" check "$tmp/warn2.kh" >"$tmp/warn2.txt" 2>&1 || w_ok=0
[[ ! -s "$tmp/warn2.txt" ]] || w_ok=0
"$KHC" --sizes -o "$tmp/warn2" "$tmp/warn2.kh" 2>/dev/null | grep ' main @' | cut -d' ' -f1 >"$tmp/warn2.size"
"$KHC" --sizes -o "$tmp/warn3" "$tmp/warn3.kh" 2>/dev/null | grep ' main @' | cut -d' ' -f1 >"$tmp/warn3.size"
[[ -s "$tmp/warn2.size" ]] && cmp -s "$tmp/warn2.size" "$tmp/warn3.size" || w_ok=0
[[ $("$tmp/warn3") == 45 ]] || w_ok=0
if [[ $w_ok -eq 1 ]]; then
	pass=$((pass + 1))
else
	failed "предупреждение W-A2" "$(cat "$tmp/warn.txt" "$tmp/warn.json" "$tmp/warn2.txt" "$tmp/warn2.size" "$tmp/warn3.size")"
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
    "gclear": ("выросшие становятся мусором\n        __gc_old_at(m, m + 56)\n", "выросшие становятся мусором\n"),
    "ptrb": ("            __gc_ptrb_on(p + off, n)\n", ""),
    "zero": ("            __memset(p + off, 0, n)\n", ""),
    "set": ("    if load64(m + 56) != 0 {\n        __map_grow_set(m, k, idx, v)\n    }\n", ""),
    "remove": ("    if load64(m + 56) != 0 {\n        __map_grow_remove(m, k, idx)\n    }\n", ""),
    "keepset": ("        // записи тот же\n        return idx\n", "        // записи тот же\n        return -1\n"),
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
# библиотеки с подложенной ошибкой тест пункта падает — без проверок (plain),
# с KHRIP_GC_VERIFY=1 (verify) или с KHRIP_GC_STRESS=1 (stress), как указано
# у каждой мутации:
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
#              заголовка (gc_satb, verify);
#   inplaceblack — массив, помеченный разметкой и выросший на месте, — без
#              новых байтов в живом (gc_inplace, verify: уборка насчитала больше);
#   inplacekept — то же в уборке, до спана (gc_inplace, stress);
#   inplaceptrb — новый хвост списка ссылок без PTRB (gc_inplace, verify);
#   reservefree — запас спана не возвращается кучке (gc_inplace, verify:
#              занятая страница без спана);
#   sharedprep — массив словаря, выросший на месте, готовится с начала:
#              записи стираются (gc_inplace, plain);
#   reservecommit — система не дала памяти на запас роста: паника посреди
#              выделения, страницы массива заняты без спана (gc_commit,
#              plain);
#   strnoscan — короткая строка store в спане со ссылками (gc_strings,
#              verify);
#   strnul — короткая строка store без места на нулевой байт (gc_strings,
#              verify: байты строки выходят за объект);
#   insertfull — insert в полный список store во время разметки не помечает
#              последний элемент, сдвинутый за старые границы выросшего на
#              месте массива (gc_insert, verify).
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
    "inplaceblack": ("    if __gc_marking != 0 && __gc_bit(GC_MARK, p) {\n        __gc_black_bytes += bytes\n    } else if", "    if false {\n        __gc_black_bytes += bytes\n    } else if", "gc.kh"),
    "inplacekept": ("        __gc_kept -= bytes\n", "", "gc.kh"),
    "inplaceptrb": ("    if !lazy && (fl & F_NOSCAN) == 0 {\n        __gc_ptrb_on(q, bytes)\n    }\n", "", "gc.kh"),
    "reservefree": ("    if np > used {\n        __ph_free_clean(__gc_ph, pg + used, np - used)\n    }\n", "", "gc.kh"),
    "sharedprep": ("        if off < start {\n            off = start\n        }\n", "", "core.kh"),
    "reservecommit": ("    let end = (at + n) << GC_PAGE_SHIFT\n    if end > __gc_committed && !__gc_commit_try(end) {\n", "    let end = (at + n) << GC_PAGE_SHIFT\n    if end > __gc_committed {\n        __gc_commit_to(end)\n    }\n    if false {\n", "gc.kh"),
    "strnoscan": ("        return __str_short(__alloc_k(len + 9, K_NOSCAN, 0), ptr, len)\n", "        return __str_short(__alloc_k(len + 9, K_PTRS, 0), ptr, len)\n", "core.kh"),
    "strnul": ("        return __str_short(__alloc_k(len + 9, K_NOSCAN, 0), ptr, len)\n", "        return __str_short(__alloc_k(len + 8, K_NOSCAN, 0), ptr, len)\n", "core.kh"),
    "insertfull": ("            __gc_insert_full(h, len)\n", "", "core.kh"),
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
	[[ $mode == stress ]] && venv=(env -u KHRIP_GC_VERIFY KHRIP_GC_STRESS=1)
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
inplaceblack gc_inplace verify
inplacekept gc_inplace stress
inplaceptrb gc_inplace verify
reservefree gc_inplace verify
sharedprep gc_inplace plain
reservecommit gc_commit plain
strnoscan gc_strings verify
strnul gc_strings verify
insertfull gc_insert verify
CUTS
[[ $mem3_ok -eq 1 ]] && pass=$((pass + 1))

# Оптимизации компилятора (этап скорости, часть 2) сами по себе: компилятор,
# собранный из копии src/ с подложенной ошибкой, собирает тест пункта
# неправильно — вывод программы (run) или блокировки маршрутов (locks) другие:
#   hoistmut — выносится и изменяемая локальная, которой присваивают в лямбде;
#   hoistopt — выносится и str? (проверка на none — внутри лямбды);
#   hoistdecl — без проверки, что имя объявлено в самой лямбде;
#   hoistparam — то же, но не смотрится параметр лямбды;
#   hoistfor, hoistlet, hoistbind — не видно for, let и привязки match (имя =>);
#   hoistend — вынесенные вызовы не забываются после лямбды (встроенная
#              функция с лямбдой — дважды подряд);
#   hoistfield — выносится и поле x.name.lower() по имени локальной name;
#   hoistdedupe — разные методы одного имени — в одной локальной;
# слияние цепочек (tests/run/chain_fusion.kh, tests/api/gc_chains.kh — test):
#   fusepure — сливается и цепочка с побочными действиями (порядок печати);
#   fuseassign — присваивание в блоке лямбды не побочное действие;
#   fusereturn — return из блока лямбды не побочное действие;
#   fusecallee — не смотрится, чисты ли вызванные функции программы;
#   fuselib — любая функция библиотеки чиста (print);
#   fuseglobal — запись в глобальную в функции программы не побочное действие;
#   fusemut — изменяющий метод в лямбде не побочное действие;
#   fusealive — обход словаря без признака «жива» (удалённые записи);
#   fusecount — обход до числа живых записей, а не до конца массивов;
#   fuseterm — цепочка не кончается на sort_by (и any, all, count, find);
#   fuseone — сливается и одно звено у списка (sort_by сортирует копию);
#   fusebox — find не кладёт значение int в коробку;
#   fusestr — sort_by по строке сравнивает слова;
#   fusefloat — ключ float без перевода в порядок целых;
#   fuseesize — список bool словами;
# свежие локальные словари в анализе чтения (tests/locks/fresh_maps.kh — locks;
# ложное read — гонка данных):
#   rwqqleft — у a ?? b свежей должна быть только правая часть;
#   rwqqoff — a ?? b по последней лексеме (groups[k] ?? xs.copy() — «свежее»);
#   rwelemstore — не смотрится, что кладут в словарь;
#   rwelemescape — словарь можно упоминать как угодно (псевдоним);
#   rwelemdecl — словарь можно объявить любым литералом;
#   rwelemstack — без предположения о своих элементах (свёртка — write);
#   rwlambda — параметр лямбды с тем же именем — всегда другое имя;
# границы выражений и имён (после ревью; tests/locks/rw_aliases.kh,
# tests/locks/rw_named.kh — locks):
#   rwscanline — выражение кончается с концом строки (?? в начале следующей
#                строки парсер присоединяет);
#   rwscanpost — постфиксы .имя, [..] на следующей строке не видны;
#   rwunsafeparam — имя параметра судится по let/var в теле;
#   rwunsafeglobal — то же для глобальной и store;
#   rwdecltwice — имя с двумя объявлениями свежее, если свежи оба;
#   rwrootsemi — присваивание в строке, которая начинается с let (через ;), —
#                «объявление»;
#   rwreassign — присваивание имени видно только в начале строки;
#   rwdecltype — тип в let/var x: тип = — любые имена и скобки до = (var x:
#                [int]; m[k] = v — «объявление» x);
#   rwuserfn — x.values() свежее и при своей функции values;
#   rwunsafeglobal, rwscanline, rwuserfn — и в анализе чистоты
#   (tests/run/chain_fusion.kh, named_cases — run);
# методы встроенных типов (tests/errors/internal_method.kh,
# tests/errors/join_not_str.kh — check):
#   methodallow — в программе можно звать и внутренние __list_*, __int_*
#                 (xs.slice, n.to_f64_bits);
#   methodrecv — получатель не сверяется с первым параметром ([1].join).
# анонимные структуры (этап токенов, часть 1; tests/run/anon_*.kh — run,
# tests/api/gc_anon.kh — test, tests/locks/anon.kh — locks, tests/errors/anon_*
# — err: сообщения компилятора отличаются от .err). Выбор литерала у {:
#   anonmapwant — ждут словарь, а {k: v} всё равно структура;
#   anonempty — {} не структура и там, где ждут структуру;
#   anonspread — { ...x } не начинает литерал структуры;
#   anonshort — { x } (одно сокращение поля) не литерал структуры;
#   anonnostruct — литерал в условии без скобок не ошибка;
#   anonea1, anonarmshort — нет ошибки E-A1 (литерал на месте блока ветки,
#                           в том числе { имя });
# тип литерала и анонимного типа:
#   anonopt — у ожидаемого T? литерал не получает T;
#   anonsum — у типа-варианта литерал без имени варианта не ошибка;
#   anonroutepick — return маршрута с двумя структурами берёт первую;
#   anonstatus — литерал после статуса (return 400 { ... }) не значение;
#   anoncall — литерал после пути call не тело;
#   anonvariants — тип { поле: T } в результате маршрута не тип;
#   anonheader, anonglobalhdr — } типа перед телом функции или перед = в
#                               store/var — «начало объявления»;
#   anonidentity — порядок полей не часть типа (порядок BSON и ответа
#                  маршрута — по первой записи);
#   anondefault — значение по умолчанию не часть типа;
#   anonordermsg — у типов другого порядка полей — общее сообщение;
#   anonguard, anonguardmention — {k: v} с переменными k молча структура;
#                  значение, которое упоминает имя поля, — тоже «словарь»;
#   anonbarekey — голое имя ключом словаря не ошибка;
#   anoncalltarget — тело call не получает тип тела маршрута;
#   anonnewline — { a ⏎ b: 2 } (сокращение, поля через перевод строки) не
#                 литерал;
#   anonforhint — у for k in {x: 1} нет подсказки про словарь;
#   anonspreadlast, anonexplicit — поле из распаковки: не из последней
#                                  или вместо явного;
#   anonwarn — W-A2 с четвёртого места, а не с третьего;
# анализ чтения:
#   anonrwtype — тип { ... } в let/var x: тип = не разобран (не объявление);
#   anonrwannot — = значения по умолчанию в таком типе — присваивание;
#   anonrwroot — объявление let x: { ... } = не узнаётся по =.
comp_ok=1
while read -r cut test mode; do
	[[ -z $cut ]] && continue
	rm -rf "${tmp:?}/msrc"
	mkdir -p "$tmp/msrc"
	cp src/*.kh "$tmp/msrc/"
	if ! python3 - "$tmp/msrc" "$cut" <<'PY'
import sys
d, m = sys.argv[1], sys.argv[2]
cuts = {
    "hoistmut": ("variant.kh", "li >= 0 && !locals[li].mutable && locals[li].ty == ty_str", "li >= 0 && locals[li].ty == ty_str"),
    "hoistopt": ("variant.kh", "li >= 0 && !locals[li].mutable && locals[li].ty == ty_str", "li >= 0 && !locals[li].mutable && (locals[li].ty == ty_str || tkind(locals[li].ty) == K_OPT)"),
    "hoistdecl": ("variant.kh", " && !declared_in(toks[j].text, from, to) && ", " && "),
    "hoistparam": ("variant.kh", "!declared_in(toks[j].text, from, to)", "!declared_in(toks[j].text, from + 2, to)"),
    "hoistfor": ("variant.kh", "            if pk == T_LET || pk == T_VAR || pk == T_FOR || kind_at(j + 1) == T_FATARROW {", "            if pk == T_LET || pk == T_VAR || kind_at(j + 1) == T_FATARROW {"),
    "hoistlet": ("variant.kh", "            if pk == T_LET || pk == T_VAR || pk == T_FOR || kind_at(j + 1) == T_FATARROW {", "            if pk == T_VAR || pk == T_FOR || kind_at(j + 1) == T_FATARROW {"),
    "hoistbind": ("variant.kh", "            if pk == T_LET || pk == T_VAR || pk == T_FOR || kind_at(j + 1) == T_FATARROW {", "            if pk == T_LET || pk == T_VAR || pk == T_FOR {"),
    "hoistend": ("variant.kh", "    while hoist_toks.len() > mark {\n        let h = hoist_locals.pop()", "    while false {\n        let h = hoist_locals.pop()"),
    "hoistfield": ("variant.kh", "if toks[j].kind == T_IDENT && toks[j - 1].kind != '.' && kind_at(j + 1) == '.'", "if toks[j].kind == T_IDENT && kind_at(j + 1) == '.'"),
    "hoistdedupe": ("variant.kh", "if toks[o].text == toks[j + 2].text && toks[o - 2].text == toks[j].text {", "if toks[o - 2].text == toks[j].text {"),
    "fusepure": ("variant.kh", "        if !lambda_pure(l.param + 2, l.close) {\n            return false\n        }\n", ""),
    "fuseassign": ("rw.kh", "            if !in_fn || fx_assign_effect(i, body, end) {", "            if in_fn && fx_assign_effect(i, body, end) {"),
    "fusereturn": ("rw.kh", "        if !in_fn && (k == T_RETURN || k == T_BREAK || k == T_CONTINUE) {", "        if false {"),
    "fusecallee": ("rw.kh", "    for c in cs {\n        if c >= fx_impure.len() || fx_impure[c] == 1 {", "    for c in cs {\n        if false {"),
    "fuselib": ("rw.kh", "fn fx_pure_lib(name: str) -> bool {\n", "fn fx_pure_lib(name: str) -> bool {\n    return true\n"),
    "fuseglobal": ("rw.kh", "    if sym >= 0 && sym_kind(sym) == SK_GLOBAL {\n        return true\n    }\n    if root == i - 1 {", "    if root == i - 1 {"),
    "fusemut": ("rw.kh", "                    if !in_fn || !rw_fresh_at(i - 2, rw_recv_start(i - 2), body, end, 0) {", "                    if in_fn && !rw_fresh_at(i - 2, rw_recv_start(i - 2), body, end, 0) {"),
    "fusealive": ("variant.kh", "        emit_movzx_index()\n        emit_test_rax()\n        nexts.push(emit_jcc(CC_E))\n        emit_local_to_rcx(idx)\n", "        emit_movzx_index()\n        emit_test_rax()\n        emit_local_to_rcx(idx)\n"),
    "fusecount": ("variant.kh", "        emit_load_local(src)\n        emit_mem_sized(0x8B, RCX, RAX, 48, false)", "        emit_load_local(src)\n        emit_mem_sized(0x8B, RCX, RAX, 8, false)"),
    "fuseterm": ("variant.kh", "        if name != \"filter\" && name != \"map\" {\n            break\n        }\n", ""),
    "fuseone": ("atom.kh", "            if links.len() >= 2 && chain_pure(links) {", "            if links.len() >= 1 && chain_pure(links) {"),
    "fusebox": ("variant.kh", "                    emit_load_local(cur)\n                    if !is_ref(et) && tkind(et) != K_OPT {\n                        emit_box()\n                    }", "                    emit_load_local(cur)"),
    "fusestr": ("variant.kh", "        if bt == ty_str {\n            emit_mov_imm(RDX, 1)\n        } else {\n            emit_mov_imm(RDX, 0)\n        }\n        emit_call(rt_func(\"__sort_by\"))\n    } else {\n        emit_load_local(res)\n    }\n    hoist_end(hmark)\n    release_hidden(cur)", "        emit_mov_imm(RDX, 0)\n        emit_call(rt_func(\"__sort_by\"))\n    } else {\n        emit_load_local(res)\n    }\n    hoist_end(hmark)\n    release_hidden(cur)"),
    "fusefloat": ("variant.kh", "                // биты double → целое того же порядка (как в parse_lambda_method)\n                emit_hex(\"48 89 C1 48 C1 F9 3F 48 D1 E9 48 31 C8\")\n", ""),
    "fuseesize": ("variant.kh", "    if makes_list {\n        put32_at(code + esize_at, esize_of(et))\n    }\n", ""),
    "rwqqleft": ("rw.kh", "            return rw_fresh_at(q - 1, a, body, end, depth + 1) && rw_fresh_at(last, q + 1, body, end, depth + 1)", "            return rw_fresh_at(last, q + 1, body, end, depth + 1)"),
    "rwqqoff": ("rw.kh", "        let q = rw_top_qq(a, last)\n", "        let q = -1\n"),
    "rwelemstore": ("rw.kh", "                    if !rw_fresh_expr(close + 2, body, end, depth + 1) {\n                        return false\n                    }\n", ""),
    "rwelemescape": ("rw.kh", "            } else if pk == T_IN && nk == '\\{' {\n            } else {\n                return false\n            }", "            }"),
    "rwelemdecl": ("rw.kh", "                if found || j < 0 || j + 2 >= end || toks[j + 1].kind != '\\{' || toks[j + 2].kind != '}' || rw_expr_scan(j + 1, end) != j + 3 {", "                if found || j < 0 {"),
    "rwelemstack": ("rw.kh", "        if s == name {\n            return true\n        }", "        if s == name {\n            return false\n        }"),
    "rwlambda": ("rw.kh", "            } else if nk == T_FATARROW && pk == '(' && at >= 0 && (at < i || at > matching_close(i - 1)) {", "            } else if nk == T_FATARROW && pk == '(' {"),
    "rwscanline": ("rw.kh", "        if i < limit && rw_binop(toks[i].kind) {\n            i += 1", "        if i < limit && rw_binop(toks[i].kind) && toks[i].line == toks[i - 1].line {\n            i += 1"),
    "rwscanpost": ("rw.kh", "        // постфиксы\n        while i < limit {", "        // постфиксы\n        while i < limit && toks[i].line == toks[i - 1].line {"),
    "rwunsafeparam": ("rw.kh", "            for p in funcs[f].params {\n                if p.name == name {\n                    return true\n                }\n            }\n", ""),
    "rwunsafeglobal": ("rw.kh", "    let sym = sym_find(name)\n    if sym >= 0 && sym_kind(sym) == SK_GLOBAL {\n        return true\n    }\n    var f = 0", "    var f = 0"),
    "rwdecltwice": ("rw.kh", "                decls += 1\n                if decls > 1 {\n                    return false\n                }\n", "                decls = 1\n"),
    "rwrootsemi": ("rw.kh", "    let root = rw_assign_root(i, body)\n    if root == -2 {", "    let root = rw_assign_root(i, body)\n    var s = i\n    while s > body && toks[s - 1].line == toks[i].line {\n        s -= 1\n    }\n    if root == -2 || toks[s].kind == T_LET || toks[s].kind == T_VAR {"),
    "rwdecltype": ("rw.kh", "        j = rw_type_end(j + 1, end)\n        if j < 0 {\n            return -1\n        }\n", "        j += 1\n        while j < end && (toks[j].kind == T_IDENT || toks[j].kind == '[' || toks[j].kind == ']' || toks[j].kind == ',' || toks[j].kind == '?') {\n            j += 1\n        }\n"),
    "rwreassign": ("rw.kh", "            } else if nk == '=' {\n                // присваивание имени", "            } else if nk == '=' && toks[i - 1].line != toks[i].line {\n                // присваивание имени"),
    "rwuserfn": ("rw.kh", "    let f = func_find(name)\n    return f >= 0 && !funcs[f].is_lib", "    return false"),
    "methodallow": ("atom.kh", "    } else if prefix.byte_len() > 0 && (system_code(nt) || builtin_method(k, name)) {", "    } else if prefix.byte_len() > 0 {"),
    "methodrecv": ("atom.kh", "            if !assignable(rt, pt) {\n                var hint = \"\"", "            if false {\n                var hint = \"\""),
    "anonmapwant": ("atom.kh", "    let t = ty_inner(w)\n    if tkind(t) == K_MAP {\n        return false\n    }\n    if struct_lit_shape(pos) {", "    let t = ty_inner(w)\n    if struct_lit_shape(pos) {"),
    "anonempty": ("atom.kh", "    return kind_at(pos + 1) == '}' && tkind(t) == K_STRUCT\n", "    return false\n"),
    "anonspread": ("atom.kh", "    if k1 == T_ELLIPSIS {\n        return true\n    }\n    if keyword_name(k1) {", "    if keyword_name(k1) {"),
    "anonshort": ("atom.kh", "    if k2 == ':' || k2 == ',' || k2 == '}' {\n", "    if k2 == ':' || k2 == ',' {\n"),
    "anonopt": ("atom.kh", "    let t = ty_inner(w)\n    let open = pos\n", "    let t = w\n    let open = pos\n"),
    "anonidentity": ("decl.kh", "                same = fs[i].name == names[i] && fs[i].ty == tys[i] && default_key(fs[i].def, fs[i].ty) == default_key(defs[i], tys[i])\n", "                let j = field_find(si, names[i])\n                same = j >= 0 && fs[j].ty == tys[i] && default_key(fs[j].def, fs[j].ty) == default_key(defs[i], tys[i])\n"),
    "anondefault": ("decl.kh", "                same = fs[i].name == names[i] && fs[i].ty == tys[i] && default_key(fs[i].def, fs[i].ty) == default_key(defs[i], tys[i])\n", "                same = fs[i].name == names[i] && fs[i].ty == tys[i]\n"),
    "anonordermsg": ("expr.kh", "    if d.starts_with(\"\\{\") {\n", "    if false {\n"),
    "anonguard": ("atom.kh", "    if plain && !bad && !panic_mode && n > 0 && reads_as_var_map(inames, itys, ivs, ive) {", "    if false {"),
    "anonguardmention": ("atom.kh", "            if toks[j].kind == T_IDENT && toks[j].text == names[i] {\n                return false\n            }", "            if false {\n                return false\n            }"),
    "anonbarekey": ("atom.kh", "        if (kind() == T_IDENT || keyword_name(kind())) && kind_at(pos + 1) == ':' {\n            // ключ — голое имя", "        if false {\n            // ключ — голое имя"),
    "anoncalltarget": ("api.kh", "        body_ty = call_body_type(method, strlits[pt.val])\n", ""),
    "anonnewline": ("atom.kh", "    return (k2 == T_IDENT || k2 == T_ELLIPSIS) && toks[i + 2].line > toks[i + 1].line\n", "    return false\n"),
    "anonforhint": ("atom.kh", "        if for_header && kind_at(pos + 1) == T_IDENT && kind_at(pos + 2) == ':' {", "        if false {"),
    "anonspreadlast": ("atom.kh", "                    } else {\n                        from_item[j] = i\n                        from_field[j] = m\n                    }\n", "                    }\n"),
    "anonexplicit": ("atom.kh", "                if !list_has(explicit, f.name) {\n                    var j = 0", "                if true {\n                    var j = 0"),
    "anonroutepick": ("api.kh", "        if other >= 0 {\n", "        if false {\n"),
    "anonstatus": ("api.kh", "        if starts_value(pos + 1) || (kind_at(pos + 1) == '\\{' && !ends_stmt(pos + 1)) {", "        if starts_value(pos + 1) {"),
    "anoncall": ("api.kh", "    var has_body = (starts_value(pos) || (kind() == '\\{' && !saved)) && tok().line == pt.line", "    var has_body = starts_value(pos) && tok().line == pt.line"),
    "anonvariants": ("api.kh", " || (kind() == '\\{' && kind_at(pos + 1) == T_IDENT && kind_at(pos + 2) == ':')", ""),
    "anonheader": ("decl.kh", "                if (k == T_FN || k == T_ROUTE || k == T_TEST) && pos > i && toks[pos].kind == '\\{' {", "                if false {"),
    "anonglobalhdr": ("decl.kh", "                if (k == T_VAR || k == T_STORE) && pos > i {", "                if false {"),
    "anonea1": ("atom.kh", "    return (k1 == T_IDENT || keyword_name(k1)) && (kind_at(i + 2) == ':' || kind_at(i + 2) == ',')\n", "    return false\n"),
    "anonarmshort": ("atom.kh", "    return brace_block_is_struct(i) || (kind_at(i + 1) == T_IDENT && kind_at(i + 2) == '}')\n", "    return brace_block_is_struct(i)\n"),
    "anonnostruct": ("atom.kh", "    if no_struct {\n        // в условии", "    if false {\n        // в условии"),
    "anonsum": ("atom.kh", "    } else if tkind(t) == K_SUM {\n        let su = types[t].a", "    } else if false {\n        let su = types[t].a"),
    "anonrwtype": ("rw.kh", "    } else if toks[j].kind == '\\{' {\n        // анонимная структура", "    } else if false {\n        // анонимная структура"),
    "anonrwannot": ("rw.kh", "        let te = rw_annot_end(i, end)\n", "        let te = -1\n"),
    "anonrwroot": ("rw.kh", " || toks[j].kind == ':' || toks[j].kind == '}') {", " || toks[j].kind == ':') {"),
    "anonwarn": ("decl.kh", "        if n >= 3 {", "        if n >= 4 {"),
}
f, old, new = cuts[m]
s = open(f"{d}/{f}").read()
if s.count(old) != 1:
    sys.exit(1)
open(f"{d}/{f}", "w").write(s.replace(old, new))
PY
	then
		comp_ok=0
		failed "оптимизации компилятора ($cut)" "место для подложенной ошибки не найдено в src/"
		continue
	fi
	if ! KHRIP_LIB="$PWD/lib" "$KHC" --system -o "$tmp/mkhc" "$tmp"/msrc/*.kh >"$tmp/mkhc.txt" 2>&1; then
		comp_ok=0
		failed "оптимизации компилятора ($cut)" "компилятор с подложенной ошибкой не собрался: $(cat "$tmp/mkhc.txt")"
		continue
	fi
	if [[ $mode == locks ]]; then
		{ KHRIP_LIB="$PWD/lib" timeout 120 "$tmp/mkhc" check --locks "$test" >"$tmp/mout.txt" 2>&1; } 2>/dev/null
	elif [[ $mode == check ]]; then
		# ошибка компиляции, которой ждёт тест, должна пропасть
		if KHRIP_LIB="$PWD/lib" timeout 120 "$tmp/mkhc" check "$test" >"$tmp/mout.txt" 2>&1; then
			continue
		fi
		comp_ok=0
		failed "оптимизации компилятора ($cut)" "$test не компилируется и без проверяемого условия: $(cat "$tmp/mout.txt")"
		continue
	elif [[ $mode == test ]]; then
		{ KHRIP_LIB="$PWD/lib" env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS timeout 300 "$tmp/mkhc" test "$test" >"$tmp/mout.txt" 2>&1; } 2>/dev/null
	elif [[ $mode == err ]]; then
		# сообщения компилятора (ошибки и предупреждения) должны стать другими
		{ KHRIP_LIB="$PWD/lib" timeout 120 "$tmp/mkhc" check "$test" >"$tmp/mout.txt" 2>&1; } 2>/dev/null
	else
		{ KHRIP_LIB="$PWD/lib" env -u KHRIP_GC_VERIFY -u KHRIP_GC_STRESS timeout 120 "$tmp/mkhc" run "$test" >"$tmp/mout.txt" 2>/dev/null; } 2>/dev/null
	fi
	ref="${test%.kh}.out"
	[[ $mode == err ]] && ref="${test%.kh}.err"
	if diff -q "$ref" "$tmp/mout.txt" >/dev/null; then
		comp_ok=0
		failed "оптимизации компилятора ($cut)" "$test проходит и без проверяемого условия"
	fi
done <<'CUTS'
hoistmut tests/run/lambda_hoist.kh run
hoistopt tests/run/lambda_hoist.kh run
hoistdecl tests/run/lambda_hoist.kh run
hoistparam tests/run/lambda_hoist.kh run
hoistfor tests/run/lambda_hoist.kh run
hoistlet tests/run/lambda_hoist.kh run
hoistbind tests/run/lambda_hoist.kh run
hoistend tests/run/lambda_hoist.kh run
hoistfield tests/run/lambda_hoist.kh run
hoistdedupe tests/run/lambda_hoist.kh run
fusepure tests/run/chain_fusion.kh run
fuseassign tests/run/chain_fusion.kh run
fusereturn tests/run/chain_fusion.kh run
fusecallee tests/run/chain_fusion.kh run
fuselib tests/run/chain_fusion.kh run
fuseglobal tests/run/chain_fusion.kh run
fusemut tests/run/chain_fusion.kh run
fusealive tests/run/chain_fusion.kh run
fusecount tests/run/chain_fusion.kh run
fuseterm tests/run/chain_fusion.kh run
fuseone tests/run/chain_fusion.kh run
fusebox tests/run/chain_fusion.kh run
fusestr tests/run/chain_fusion.kh run
fusefloat tests/run/chain_fusion.kh run
fuseesize tests/run/chain_fusion.kh run
fusealive tests/api/gc_chains.kh test
fusecount tests/api/gc_chains.kh test
rwqqleft tests/locks/fresh_maps.kh locks
rwqqoff tests/locks/fresh_maps.kh locks
rwelemstore tests/locks/fresh_maps.kh locks
rwelemescape tests/locks/fresh_maps.kh locks
rwelemdecl tests/locks/fresh_maps.kh locks
rwelemstack tests/locks/fresh_maps.kh locks
rwlambda tests/locks/fresh_maps.kh locks
rwscanline tests/locks/rw_aliases.kh locks
rwscanpost tests/locks/rw_aliases.kh locks
rwunsafeparam tests/locks/rw_aliases.kh locks
rwunsafeglobal tests/locks/rw_aliases.kh locks
rwdecltwice tests/locks/rw_aliases.kh locks
rwrootsemi tests/locks/rw_aliases.kh locks
rwreassign tests/locks/rw_aliases.kh locks
rwdecltype tests/locks/rw_aliases.kh locks
rwuserfn tests/locks/rw_named.kh locks
rwunsafeglobal tests/run/chain_fusion.kh run
rwscanline tests/run/chain_fusion.kh run
rwuserfn tests/run/chain_fusion.kh run
methodallow tests/errors/internal_method.kh check
methodrecv tests/errors/join_not_str.kh check
anonmapwant tests/errors/anon_cond.kh err
anonempty tests/run/anon_literals.kh run
anonspread tests/run/anon_literals.kh run
anonshort tests/run/anon_literals.kh run
anonopt tests/run/anon_literals.kh run
anonidentity tests/run/anon_types.kh run
anondefault tests/run/anon_types.kh run
anonidentity tests/run/anon_bson_order.kh run
anonidentity tests/api/gc_anon.kh test
anonordermsg tests/errors/anon_order.kh err
anonguard tests/errors/anon_map_guard.kh err
anonguardmention tests/run/anon_literals.kh run
anonbarekey tests/errors/anon_cond.kh err
anoncalltarget tests/errors/anon_call_typo.kh err
anonnewline tests/run/anon_literals.kh run
anonforhint tests/errors/anon_cond.kh err
anonspreadlast tests/run/anon_literals.kh run
anonexplicit tests/run/anon_literals.kh run
anonroutepick tests/errors/anon_variant.kh err
anonstatus tests/api/gc_anon.kh test
anoncall tests/api/gc_anon.kh test
anonvariants tests/api/gc_anon.kh test
anonheader tests/run/anon_types.kh run
anonglobalhdr tests/api/gc_anon.kh test
anonea1 tests/errors/anon_match_arm.kh err
anonarmshort tests/errors/anon_match_arm.kh err
anonnostruct tests/errors/anon_cond.kh err
anonsum tests/errors/anon_variant.kh err
anonrwtype tests/locks/anon.kh locks
anonrwannot tests/locks/anon.kh locks
anonrwroot tests/locks/anon.kh locks
anonwarn tests/errors/anon_warn.kh err
CUTS
[[ $comp_ok -eq 1 ]] && pass=$((pass + 1))
# Слияние срабатывает: в eval/solutions/bookings все values() — в цепочках
# лямбд без побочных действий, и списка values() (__map_values) в программе нет.
if "$KHC" --sizes -o "$tmp/fused" eval/solutions/bookings/khrip/main.kh >"$tmp/fused.txt" 2>&1 && ! grep -q ' __map_values ' "$tmp/fused.txt"; then
	pass=$((pass + 1))
else
	failed "слияние цепочек в bookings" "$(grep ' __map_values ' "$tmp/fused.txt" || cat "$tmp/fused.txt")"
fi

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
# Сгенерированные программы (tests/rw_gen.py): сотни маршрутов, где значение
# store доходит до локальной через ?? на следующей строке, ;, скобки, if и
# match, свежие словари, с приманками — локальными с именем store или
# параметра, вторым объявлением, своей функцией copy. Ни одного ложного read.
mkdir -p "$tmp/rw_gen"
for seed in 1 2 3; do
	if python3 tests/rw_gen.py "$KHC" "$tmp/rw_gen" "$seed" >"$tmp/rw_gen.txt" 2>&1; then
		pass=$((pass + 1))
	else
		failed "tests/rw_gen.py (seed $seed)" "$(tail -20 "$tmp/rw_gen.txt")"
	fi
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

# Скилл Khrip (skill/khrip, см. начало файла). Токены — весь текст файла, как
# его читает модель: ядро SKILL.md грузится всегда, главы — по задаче.
skill_md=(skill/khrip/*.md)
if ! command -v node >/dev/null; then
	echo "SKIP skill/khrip: нет node — бюджеты токенов не проверены"
elif [[ ! -d eval/tokens/node_modules/gpt-tokenizer ]] && ! npm install --prefix eval/tokens --silent --no-audit --no-fund >/dev/null 2>&1; then
	echo "SKIP skill/khrip: нет gpt-tokenizer (npm install --prefix eval/tokens) — бюджеты токенов не проверены"
elif ! node eval/tokens/count.mjs --raw "${skill_md[@]}" >"$tmp/skill_tokens.txt" 2>&1 || [[ $(wc -l <"$tmp/skill_tokens.txt") -ne ${#skill_md[@]} ]]; then
	failed "skill/khrip" "токены не посчитаны: $(cat "$tmp/skill_tokens.txt")"
else
	while IFS=$'\t' read -r n f; do
		limit=900
		[[ $(basename "$f") == SKILL.md ]] && limit=3000
		if [[ $n -le $limit ]]; then
			pass=$((pass + 1))
		else
			failed "$f" "$n токенов o200k, больше $limit"
		fi
	done <"$tmp/skill_tokens.txt"
fi
if command -v python3 >/dev/null; then
	. eval/server.sh
	skill_pg=${KHRIP_TEST_DATABASE_URL:-$EVAL_PG}
	if [[ -z $PSQL ]] || ! "$PSQL" -q "$skill_pg" -c "select 1" >/dev/null 2>&1; then
		skill_pg=
	fi
	mkdir -p "$tmp/skill"
	SKILL_PG=$skill_pg python3 -I tests/skill/check.py "$KHC" "$tmp/skill" >"$tmp/skill.txt" 2>&1
	skill_pass=
	skill_fail=
	read -r _ skill_pass skill_fail < <(tail -1 "$tmp/skill.txt")
	if [[ $skill_pass =~ ^[0-9]+$ && $skill_fail =~ ^[0-9]+$ ]]; then
		pass=$((pass + skill_pass))
		fail=$((fail + skill_fail))
		grep '^SKIP' "$tmp/skill.txt"
		[[ $skill_fail -gt 0 ]] && sed '$d' "$tmp/skill.txt" | grep -v '^SKIP'
	else
		failed "tests/skill/check.py" "$(cat "$tmp/skill.txt")"
	fi
fi

echo "тестов пройдено: $pass, провалено: $fail"
[[ $fail -eq 0 ]]
