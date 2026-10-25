# Сопрограммы сервера: запросы, которые ждут (sleep, fetch), не держат поток.
# Подключается из tests/run.sh (использует KHC, tmp, failed и функции из
# tests/http.sh). Сервер — tests/coro/server.kh, один рабочий поток.

CORO_PORT=${CORO_PORT:-18182}

if ! "$KHC" -o "$tmp/coro" tests/coro/server.kh 2>"$tmp/coro.err"; then
	failed "coro" "сервер не скомпилировался: $(cat "$tmp/coro.err")"
	return 0
fi

coro_bin=$tmp/coro
coro_start() {
	PORT=$CORO_PORT THREADS=1 "$@" "$coro_bin" 2>"$tmp/coro.log" &
	coro_pid=$!
	for _ in $(seq 100); do
		curl -s -o /dev/null "http://127.0.0.1:$CORO_PORT/log" && break
		sleep 0.02
	done
}

coro_stop() {
	kill "$coro_pid"
	wait "$coro_pid" 2>/dev/null
}

ms_now() {
	echo $(($(date +%s%N) / 1000000))
}

# Ждать только своих curl: wait без аргументов ждал бы и сервер.
curl_many() {
	local n=$1 pids=()
	shift
	for _ in $(seq "$n"); do
		curl -s -o /dev/null -w '%{http_code}\n' "$@" &
		pids+=($!)
	done
	wait "${pids[@]}"
}

# Рабочих потоков не больше 4000 (реестр потоков сборщика store, lib/gc.kh):
# больше — отказ при старте, а не выход посреди работы.
r=$(PORT=$CORO_PORT THREADS=5000 timeout 5 "$coro_bin" 2>&1)
rc=$?
if [[ $rc == 1 && "$r" == *"THREADS=5000: at most 4000 worker threads"* ]]; then
	http_ok
else
	failed "coro: THREADS сверх предела" "код $rc: $r"
fi

coro_start env
url="http://127.0.0.1:$CORO_PORT"

t0=$(ms_now)
r=$(curl_many 50 "$url/sleep?ms=300" | sort | uniq -c | tr -s ' ')
t1=$(ms_now)
expect_count "50 запросов со sleep(300) на одном потоке" "$r" "^ 50 200$" 1
if ((t1 - t0 < 1500)); then http_ok; else failed "coro: ожидания параллельны" "заняли $((t1 - t0)) мс"; fi

r=$(curl -s "$url/self?port=$CORO_PORT")
expect_count "fetch к себе на одном потоке" "$r" "^200 slept inner$" 1

r=$(curl_many 20 "$url/self?port=$CORO_PORT" | sort | uniq -c | tr -s ' ')
expect_count "20 одновременных fetch к себе" "$r" "^ 20 200$" 1

r=$(curl -s "$url/deep?n=20000")
expect_count "глубокий стек сохраняется на время ожидания" "$r" "^20000$" 1

r=$(curl -s -w ' %{http_code}' "$url/boom")
expect_count "паника после ожидания — 500" "$r" "^Internal Server Error 500$" 1

r=$(curl -s -w ' %{http_code}' "$url/deny")
expect_count "fail после ожидания" "$r" "^denied 403$" 1

r=$(HTTP_PORT=$CORO_PORT http_raw 'GET /sleep?ms=200&tag=A HTTP/1.1\r\nHost: x\r\n\r\nGET /sleep?ms=1&tag=B HTTP/1.1\r\nHost: x\r\n\r\nGET /sleep?ms=50&tag=C HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
expect_count "конвейер: ответы по порядку, хотя первый ждёт" "$(grep -oE 'slept [A-C]' <<<"$r" | tr '\n' ' ')" "^slept A slept B slept C $" 1

curl_many 100 -X POST "$url/log?text=t" >/dev/null
r=$(curl -s "$url/log")
expect_count "запись в store через ожидание: ничего не потеряно" "$r" "^200$" 1

# соединения fetch к себе остаются в запасе (keep-alive): база — после них
fds=$(ls "/proc/$coro_pid/fd" | wc -l)
curl_many 100 --max-time 0.05 "$url/sleep?ms=300" >/dev/null
sleep 0.5
r=$(ls "/proc/$coro_pid/fd" | wc -l)
expect_count "клиенты ушли, не дождавшись: соединения закрыты" "$r" "^$fds$" 1
r=$(curl -s "$url/sleep?ms=1&tag=alive")
expect_count "сервер жив после ушедших клиентов" "$r" "^slept alive$" 1

# Кэш строк через ожидание: четыре /walk по строкам в 64 КБ засыпают каждые 16
# шагов, а между ними на том же потоке идут 40 запросов /text. Ответы — как у
# тех же запросов по одному (без ожиданий), проход /walk — линейный.
for s in 1 2 3 4; do
	curl -s -w '\n' "$url/walk?seed=$s&nap=0"
done >"$tmp/walk.want"
for s in $(seq 40); do
	curl -s -w '\n' "$url/text?seed=$s"
done >"$tmp/text.want"
walk_pids=()
for s in 1 2 3 4; do
	curl -s -o "$tmp/walk.$s" "$url/walk?seed=$s&nap=16" &
	walk_pids+=($!)
done
sleep 0.05
for s in $(seq 40); do
	curl -s -o "$tmp/text.$s" "$url/text?seed=$s" &
	walk_pids+=($!)
done
wait "${walk_pids[@]}"
for s in 1 2 3 4; do
	cat "$tmp/walk.$s"
	echo
done >"$tmp/walk.got"
for s in $(seq 40); do
	cat "$tmp/text.$s"
	echo
done >"$tmp/text.got"
if cmp -s "$tmp/walk.want" "$tmp/walk.got" && cmp -s "$tmp/text.want" "$tmp/text.got" && [[ $(grep -c ' linear$' "$tmp/walk.got") == 4 ]]; then
	http_ok
else
	failed "coro: кэш строк через ожидание" "$(diff "$tmp/walk.want" "$tmp/walk.got"; diff "$tmp/text.want" "$tmp/text.got" | head -5)"
fi
coro_stop

# Окна без блокировки store (docs/design/v0.13-store-gc.md §6): пока пишущий
# запрос ждёт fetch к себе (окно: блокировка отпущена, запись контекста
# опубликована), читающий и пишущие запросы на том же единственном потоке идут
# сразу — если бы окно держало блокировку, поток встал бы навсегда; строка
# store и список в арене, которые держит ждущий, после окна те же. Хеш пароля
# — тоже окно.
coro_windows() {
	local tag=$1 t0 t1 t2 t3 hold_pid r r2
	t0=$(ms_now)
	curl -s --max-time 10 -X POST "$url/hold?port=$CORO_PORT&ms=600&tag=$tag" >"$tmp/hold.out" &
	hold_pid=$!
	sleep 0.15
	r=$(curl -s --max-time 5 "$url/marks")
	t1=$(ms_now)
	r2=$(curl_many 5 --max-time 5 -X POST "$url/log?text=w" | sort | uniq -c | tr -s ' ')
	t2=$(ms_now)
	wait "$hold_pid"
	t3=$(ms_now)
	if [[ "$r" =~ ^[0-9]+$ && "$r" -ge 1 && "$r2" == " 5 200" ]] && ((t1 - t0 < 500 && t2 - t0 < 600 && t3 - t0 >= 600)); then
		http_ok
	else
		failed "coro: store читают и пишут, пока запрос ждёт fetch ($tag)" "marks: $r, log: $r2, чтение через $((t1 - t0)) мс, запись через $((t2 - t0)) мс, ждущий — $((t3 - t0)) мс"
	fi
	expect_count "запрос держит store через fetch ($tag)" "$(cat "$tmp/hold.out")" "^200 slept $tag held-$tag$" 1
	r=$(curl_many 3 --max-time 10 -X POST "$url/hash?tag=$tag" | sort | uniq -c | tr -s ' ')
	expect_count "хеш пароля без блокировки store ($tag)" "$r" "^ 3 200$" 1
	r=$(curl -s --max-time 10 -X POST "$url/hash?tag=$tag")
	expect_count "хеш пароля: строка store цела ($tag)" "$r" "^hash-$tag$" 1
}

coro_start env
coro_windows plain
coro_stop

# То же с проверками сборщика (KHRIP_GC_VERIFY=1): каждое исключительное
# взятие store проверяет, что каждый контекст, который брал store и отпустил
# его посреди работы, опубликовал запись (их встретилось больше нуля), а при
# отзыве — что окно не изменило ссылки в арене ниже границы записи (W1).
if KHRIP_GC_VERIFY=1 "$KHC" -o "$tmp/coro_v" tests/coro/server.kh 2>"$tmp/coro.err"; then
	coro_bin=$tmp/coro_v
	coro_start env KHRIP_GC_VERIFY=1
	coro_windows verify
	r=$(curl -s "$url/gcv")
	if [[ "$r" =~ ^[0-9]+\ [0-9]+$ && "${r#* }" -gt 0 ]] && ! grep -q 'gc verify:' "$tmp/coro.log"; then
		http_ok
	else
		failed "coro: записи опубликованы при каждой проверке начала сборки" "проверок и записей: $r; журнал: $(cat "$tmp/coro.log")"
	fi
	coro_stop
	coro_bin=$tmp/coro
else
	failed "coro" "сервер с проверками не скомпилировался: $(cat "$tmp/coro.err")"
fi

# две сопрограммы на поток: остальные запросы ждут в очереди
coro_start env KHRIP_COROUTINES=2
t0=$(ms_now)
r=$(curl_many 10 "$url/sleep?ms=100" | sort | uniq -c | tr -s ' ')
t1=$(ms_now)
expect_count "очередь: все 10 запросов выполнены" "$r" "^ 10 200$" 1
if ((t1 - t0 >= 450)); then http_ok; else failed "coro: две сопрограммы" "10 запросов заняли $((t1 - t0)) мс, а должны — не меньше 500"; fi
coro_stop

# fetch: соединения переиспользуются, ответы любой формы читаются до конца
if command -v python3 >/dev/null; then
	up_port=$((CORO_PORT + 1))
	python3 tests/coro/upstream.py "$up_port" &
	up_pid=$!
	coro_start env
	for _ in $(seq 50); do
		(exec 3<>"/dev/tcp/127.0.0.1/$up_port") 2>/dev/null && break
		sleep 0.02
	done
	for p in "chunked:200:hello world" "len:200:abc" "eof:200:until-eof" "nolen:200:old-style" "drop:0:connection closed without a response"; do
		path=${p%%:*}
		want=${p#*:}
		r=$(curl -s "$url/twice?port=$up_port&path=$path")
		expect_count "fetch: ответ «$path»" "$r" "^$want|$want$" 1
	done
	r=$(curl -s -X POST "$url/post?port=$up_port")
	expect_count "fetch: POST по соединению из запаса" "$r" "^200:abc$" 1
	# сервис перезапущен: соединения из запаса мертвы, fetch открывает новые
	kill "$up_pid"
	wait "$up_pid" 2>/dev/null
	python3 tests/coro/upstream.py "$up_port" &
	up_pid=$!
	sleep 0.3
	r=$(curl -s "$url/twice?port=$up_port&path=len")
	expect_count "fetch: сервис перезапущен — новое соединение" "$r" "^200:abc|200:abc$" 1
	coro_stop
	kill "$up_pid"
	wait "$up_pid" 2>/dev/null
fi
