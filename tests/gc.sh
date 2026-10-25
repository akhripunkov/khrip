# Матрица держателей сборщика store (docs/design/v0.13-store-gc.md §15.2,
# §15.3): сервер tests/gc/server.kh на 4 потоках под нагрузкой tests/gc/drive.py
# — писатели всё время заменяют товары, а запросы держат значения store через
# sleep, хеш пароля, fetch, циклы, временные значения, долгий опрос, паники в
# окнах, фоновая задача — пока идут сборки. Без проверок и с
# KHRIP_GC_STRESS=1 (сборка очень часто, с проверками KHRIP_GC_VERIFY=1): ни
# одного неверного ответа, ни одной ошибки проверок, счётчик и деньги сходятся,
# память store ограничена. Затем KHRIP_DATA: сохранение под нагрузкой (SIGTERM),
# перезапуск и восстановление со сборками — снимок цел. Сборка в простое после
# записи без выделений. И тест внутри
# tests/gc/server.kh: khc test держит товар через call, без проверок и со
# KHRIP_GC_STRESS=1. Подключается из tests/run.sh (использует KHC, tmp, failed,
# http_ok).

GC_PORT=${GC_PORT:-$((HTTP_PORT + 30))}
gc_up=$((GC_PORT + 1))
gc_url=http://127.0.0.1:$GC_PORT

python3 tests/coro/upstream.py "$gc_up" >/dev/null 2>&1 &
gc_up_pid=$!

# gc_start <бинарник> [переменные...]: сервер; ждёт, пока ответит
gc_start() {
	local bin=$1
	shift
	env PORT=$GC_PORT THREADS=4 UPSTREAM_PORT=$gc_up KHRIP_GC_LOG=1 "$@" "$bin" 2>"$tmp/gc.log" &
	gc_pid=$!
	for _ in $(seq 200); do
		curl -s -o /dev/null "$gc_url/count" && return
		sleep 0.05
	done
}

gc_stop() {
	kill -TERM "$gc_pid" 2>/dev/null
	wait "$gc_pid" 2>/dev/null
}

# gc_matrix <имя> <бинарник> <секунд> [переменные...]: запас кучи — 20%, цель
# — от 1 МБ, поэтому сборки идут часто и тогда, когда проверки
# (KHRIP_GC_VERIFY=1 набора) замедляют сервер в десятки раз
gc_matrix() {
	local name=$1 bin=$2 secs=$3
	shift 3
	gc_start "$bin" KHRIP_GC=20 KHRIP_GC_MIN_MB=1 "$@"
	curl -s -o /dev/null -X POST "$gc_url/seed"
	local out rss alive=0 cycles verify
	out=$(python3 tests/gc/drive.py load "$GC_PORT" "$secs" 2>&1)
	rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$gc_pid/status" 2>/dev/null)
	kill -0 "$gc_pid" 2>/dev/null && alive=1
	gc_stop
	cycles=$(grep -c '^gc [0-9]* (' "$tmp/gc.log")
	verify=$(grep 'gc verify' "$tmp/gc.log" | grep -cv 'gc verify (boot): ')
	if python3 - "$out" "$alive" "$cycles" "$verify" "${rss:-0}" >"$tmp/gc.check" 2>&1 <<'PY'; then
import json, sys
out, alive, cycles, verify, rss = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
r = json.loads(out)
errs = []
if not alive:
    errs.append("the server died")
if verify:
    errs.append(f"{verify} verify failures")
if cycles < 3:
    errs.append(f"only {cycles} collections")
if r["bad"]:
    errs.append("wrong answers: " + "; ".join(r["bad"]))
for route in ["churn", "hold", "slice", "loop", "temps", "map", "search", "resurrect", "poll", "login", "rotate", "fx", "hdrs", "boom", "bump", "transfer", "feed"]:
    if r["routes"].get(route, [0])[0] == 0:
        errs.append(f"no {route} requests")
if r["count"] != f"{r['bumps']} {r['bumps']}":
    errs.append(f"lost increments: {r['count']} for {r['bumps']}")
if r["sum"] != "100000":
    errs.append(f"money: {r['sum']}")
runs, ok, bad = map(int, r["every"].split())
if runs < 3 or bad:
    errs.append(f"every: {r['every']}")
if not r["resurrected"].startswith("ok"):
    errs.append(f"resurrected: {r['resurrected']}")
if r["poll"] != "ok":
    errs.append(f"final check: {r['poll']}")
# память: цель кучи (4 МБ), долгие опросы держат по снимку товаров, остальное —
# стеки и арены сопрограмм
if rss > 48 * 1024:
    errs.append(f"RSS {rss} KB")
print(f"{cycles} collections, RSS {rss} KB, " + ", ".join(f"{k} {v[0]}" for k, v in sorted(r["routes"].items())))
if errs:
    print("; ".join(errs))
    sys.exit(1)
PY
		http_ok
		echo "gc matrix ($name): $(head -1 "$tmp/gc.check")"
	else
		failed "gc: матрица держателей ($name)" "$(cat "$tmp/gc.check")"$'\n'"$(grep -v '^gc [0-9]' "$tmp/gc.log" | tail -5)"
	fi
}

if "$KHC" -o "$tmp/gcsrv" tests/gc/server.kh 2>"$tmp/gcsrv.err" && KHRIP_GC_STRESS=1 "$KHC" -o "$tmp/gcsrv_s" tests/gc/server.kh 2>>"$tmp/gcsrv.err"; then
	gc_matrix plain "$tmp/gcsrv" 8
	gc_matrix "KHRIP_GC_STRESS=1" "$tmp/gcsrv_s" 8 KHRIP_GC_STRESS=1

	# KHRIP_DATA: SIGTERM посреди нагрузки сохраняет целый снимок; перезапуск
	# восстанавливает его, сборки идут дальше, второй снимок тоже цел
	rm -f "$tmp/gc.json"
	gc_start "$tmp/gcsrv" KHRIP_DATA="$tmp/gc.json"
	curl -s -o /dev/null -X POST "$gc_url/seed"
	python3 tests/gc/drive.py load "$GC_PORT" 3 >/dev/null 2>&1 &
	gc_drv=$!
	sleep 2
	gc_stop
	wait "$gc_drv" 2>/dev/null
	c1=$(python3 tests/gc/drive.py check "$tmp/gc.json" 2>&1)
	gc_start "$tmp/gcsrv" KHRIP_DATA="$tmp/gc.json"
	r1=$(curl -s "$gc_url/poll?ms=0")
	r2=$(curl -s "$gc_url/sum")
	for i in $(seq 0 40 1999); do
		curl -s -o /dev/null -X POST "$gc_url/churn/$i/400"
	done
	r3=$(curl -s "$gc_url/poll?ms=0")
	gc_stop
	cyc=$(grep -c '^gc [0-9]* (' "$tmp/gc.log")
	c2=$(python3 tests/gc/drive.py check "$tmp/gc.json" 2>&1)
	want='{"products": 2000, "bad": [], "money": 100000}'
	if [[ "$c1" == "$want" && "$c2" == "$want" && "$r1 $r2 $r3" == "ok 100000 ok" ]] && ((cyc >= 1)); then
		http_ok
	else
		failed "gc: KHRIP_DATA под сборкой" "снимок под нагрузкой: $c1; после восстановления: $r1 $r2 $r3, сборок $cyc; второй снимок: $c2"$'\n'"$(grep -v '^gc [0-9]' "$tmp/gc.log" | tail -5)"
	fi
	# простой: 32 МБ store становятся мусором без новых выделений (замена
	# пустым списком) — сборку делает простой потока сборщика (10 с без
	# выделений, но store брали на запись), и память уходит системе
	gc_start "$tmp/gcsrv"
	curl -s -o /dev/null -X POST "$gc_url/big/4000000"
	read -r c0 _ < <(curl -s "$gc_url/gcstats")
	r0=$(awk '/^VmRSS:/ { print $2 }' "/proc/$gc_pid/status")
	curl -s -o /dev/null -X POST "$gc_url/big-drop"
	c1=$c0
	for _ in $(seq 40); do
		sleep 0.5
		read -r c1 _ < <(curl -s "$gc_url/gcstats")
		((c1 > c0)) && break
	done
	sleep 0.5
	r1=$(awk '/^VmRSS:/ { print $2 }' "/proc/$gc_pid/status")
	gc_stop
	if ((c1 > c0 && r0 - r1 > 24 * 1024)) && grep -q '^gc [0-9]* (idle)' "$tmp/gc.log"; then
		http_ok
	else
		failed "gc: сборка в простое после записи без выделений" "сборок $c0 -> $c1, RSS $r0 -> $r1 КБ"$'\n'"$(tail -3 "$tmp/gc.log")"
	fi

	for mode in "" KHRIP_GC_STRESS=1; do
		# shellcheck disable=SC2086
		env -u KHRIP_GC_VERIFY $mode "$KHC" test tests/gc/server.kh 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/gctest.out"
		if [[ "$(cat "$tmp/gctest.out")" == *"1 tests: 1 passed, 0 failed" ]]; then
			http_ok
		else
			failed "khc test tests/gc/server.kh ${mode:-}" "$(cat "$tmp/gctest.out")"
		fi
	done
else
	failed "tests/gc/server.kh" "$(cat "$tmp/gcsrv.err")"
fi

kill "$gc_up_pid" 2>/dev/null
wait "$gc_up_pid" 2>/dev/null
