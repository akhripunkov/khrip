# Тесты HTTP-сервера bench/khrip/server.kh. Подключается из tests/run.sh
# (использует его переменные KHC, tmp и функцию failed).

HTTP_PORT=${HTTP_PORT:-18181}

http_ok() {
	pass=$((pass + 1))
}

# Отправляет сырые байты в одном соединении и печатает всё, что ответил сервер.
# Соединение закрывает сервер (Connection: close) или таймаут.
http_raw() {
	exec 3<>"/dev/tcp/127.0.0.1/$HTTP_PORT"
	printf "$1" >&3
	if [[ -n "${2:-}" ]]; then
		sleep 0.2
		printf "$2" >&3
	fi
	timeout 2 cat <&3 2>/dev/null | tr -d '\r'
	exec 3<&-
}

# expect_count <название> <текст> <образец> <сколько раз>
# Считаются вхождения, а не строки: тело ответа не заканчивается переводом
# строки, и следующий ответ в том же соединении начинается на той же строке.
expect_count() {
	local got
	got=$(grep -o -- "$3" <<<"$2" | wc -l)
	if [[ "$got" == "$4" ]]; then
		http_ok
	else
		failed "http: $1" "«$3» встретилось $got раз, ожидалось $4; ответ:"$'\n'"$2"
	fi
}

if ! command -v curl >/dev/null; then
	echo "пропуск HTTP-тестов: нет curl"
	return 0
fi

if ! "$KHC" -o "$tmp/server" bench/khrip/server.kh 2>"$tmp/server.err"; then
	failed "http" "сервер не скомпилировался: $(cat "$tmp/server.err")"
	return 0
fi
PORT=$HTTP_PORT "$tmp/server" 2>/dev/null &
server_pid=$!
for _ in $(seq 100); do
	curl -s -o /dev/null "http://127.0.0.1:$HTTP_PORT/plaintext" && break
	sleep 0.02
done

url="http://127.0.0.1:$HTTP_PORT"

r=$(curl -s -i "$url/plaintext" | tr -d '\r')
expect_count "plaintext: статус" "$r" "^HTTP/1.1 200 OK$" 1
expect_count "plaintext: тело" "$r" "^Hello, World!$" 1
expect_count "plaintext: длина" "$r" "^Content-Length: 13$" 1
expect_count "plaintext: дата" "$r" "^Date: [A-Z][a-z][a-z], [0-9][0-9] [A-Z][a-z][a-z] 20[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] GMT$" 1
expect_count "plaintext: тип" "$r" "^Content-Type: text/plain; charset=utf-8$" 1

r=$(curl -s -i "$url/json" | tr -d '\r')
expect_count "json: тело" "$r" '^{"message":"Hello, World!"}$' 1
expect_count "json: тип" "$r" "^Content-Type: application/json$" 1

r=$(curl -s -i "$url/plaintext?x=1&y=2" | tr -d '\r')
expect_count "строка запроса не мешает маршруту" "$r" "^HTTP/1.1 200 OK$" 1

r=$(curl -s -i "$url/nope" | tr -d '\r')
expect_count "неизвестный путь" "$r" "^HTTP/1.1 404 Not Found$" 1

r=$(curl -s -i -X DELETE "$url/plaintext" | tr -d '\r')
expect_count "известный путь, другой метод" "$r" "^HTTP/1.1 405 Method Not Allowed$" 1

r=$(curl -s -o /dev/null -o /dev/null -w '%{num_connects}\n' "$url/plaintext" "$url/json")
expect_count "keep-alive: второй запрос в том же соединении" "$r" "^0$" 1

r=$(http_raw 'GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\nGET /json HTTP/1.1\r\nHost: x\r\n\r\nGET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
expect_count "конвейер: три ответа" "$r" "HTTP/1.1 200 OK" 3
expect_count "конвейер: порядок" "$(grep -oE 'Hello, World!"?' <<<"$r" | tr '\n' ' ')" '^Hello, World! Hello, World!" Hello, World! $' 1
expect_count "конвейер: закрытие по Connection: close" "$r" "^Connection: close$" 1

r=$(http_raw 'GET /plain' 'text HTTP/1.1\r\nConnection: close\r\n\r\n')
expect_count "запрос, пришедший по частям" "$r" "^Hello, World!$" 1

r=$(http_raw 'POST /plaintext HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET /plaintext HTTP/1.1\r\nConnection: close\r\n\r\n')
expect_count "тело пропускается, следующий запрос цел" "$(grep -oE 'HTTP/1.1 [0-9]+' <<<"$r" | tr '\n' ' ')" "^HTTP/1.1 405 HTTP/1.1 200 $" 1

r=$(http_raw 'POST /plaintext HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel' 'loGET /plaintext HTTP/1.1\r\nConnection: close\r\n\r\n')
expect_count "тело, пришедшее по частям" "$(grep -oE 'HTTP/1.1 [0-9]+' <<<"$r" | tr '\n' ' ')" "^HTTP/1.1 405 HTTP/1.1 200 $" 1

r=$(http_raw 'GET /plaintext HTTP/1.0\r\n\r\n')
expect_count "HTTP/1.0 закрывает соединение" "$r" "^Connection: close$" 1

r=$(http_raw 'garbage\r\n\r\n')
expect_count "мусор вместо запроса" "$r" "^HTTP/1.1 400 Bad Request$" 1

r=$(http_raw 'GET /plaintext HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n')
expect_count "chunked пока не поддерживается" "$r" "^HTTP/1.1 501 Not Implemented$" 1

r=$(http_raw "GET /plaintext HTTP/1.1\r\nX-Big: $(head -c 70000 /dev/zero | tr '\0' 'a')")
expect_count "слишком большие заголовки" "$r" "^HTTP/1.1 431 Request Header Fields Too Large$" 1

r=$(curl -s "$url/plaintext")
expect_count "сервер жив после ошибок" "$r" "^Hello, World!$" 1

kill "$server_pid"
wait "$server_pid" 2>/dev/null

# Запись в store из встроенной функции под одновременной нагрузкой: блокировка
# store берётся и там (раньше встроенный код писал без неё и терял обновления).
inl_port=$((HTTP_PORT + 1))
if "$KHC" -o "$tmp/inline_store" tests/load/inline_store.kh >"$tmp/inline_store.err" 2>&1; then
	PORT=$inl_port THREADS=4 "$tmp/inline_store" 2>/dev/null &
	inl_pid=$!
	for _ in $(seq 100); do
		curl -s -o /dev/null "http://127.0.0.1:$inl_port/count" && break
		sleep 0.05
	done
	seq 2000 | xargs -P 32 -I{} curl -s -o /dev/null -X POST "http://127.0.0.1:$inl_port/bump/{}"
	r=$(curl -s "http://127.0.0.1:$inl_port/count")
	kill "$inl_pid"
	wait "$inl_pid" 2>/dev/null
	if [[ "$r" == "2000 2000" ]]; then
		http_ok
	else
		failed "http: store из встроенной функции" "ожидалось «2000 2000», получено «$r»"
	fi
else
	failed "tests/load/inline_store.kh" "$(cat "$tmp/inline_store.err")"
fi

# Цикл в store: JSON с ним — 500; сохранение KHRIP_DATA (раз в секунду и по
# SIGTERM) сообщает об ошибке и оставляет старый файл, сервер жив.
cyc_port=$((HTTP_PORT + 2))
if "$KHC" -o "$tmp/cycle_store" tests/load/cycle_store.kh >"$tmp/cycle_store.err" 2>&1; then
	printf '{"nodes":{"1":{"name":"a","next":null}}}' >"$tmp/cycle.json"
	cp "$tmp/cycle.json" "$tmp/cycle.orig"
	PORT=$cyc_port KHRIP_DATA="$tmp/cycle.json" "$tmp/cycle_store" 2>"$tmp/cycle.log" &
	cyc_pid=$!
	for _ in $(seq 100); do
		curl -s -o /dev/null "http://127.0.0.1:$cyc_port/count" && break
		sleep 0.05
	done
	r=$(curl -s "http://127.0.0.1:$cyc_port/nodes/1")
	r="$r $(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$cyc_port/cycle/1")"
	r="$r $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$cyc_port/nodes/1")"
	sleep 1.5
	r="$r $(curl -s "http://127.0.0.1:$cyc_port/count")"
	kill -TERM "$cyc_pid"
	wait "$cyc_pid" 2>/dev/null
	msgs=$(grep -c '^khrip: cannot save store: value has a cycle at Node$' "$tmp/cycle.log")
	if [[ "$r" == '{"name":"a","next":null} 204 500 1' ]] && cmp -s "$tmp/cycle.json" "$tmp/cycle.orig" && ((msgs >= 1 && msgs <= 2)); then
		http_ok
	else
		failed "http: цикл в store и KHRIP_DATA" "ответы «$r», сообщений об ошибке: $msgs, файл: $(cat "$tmp/cycle.json"); журнал: $(cat "$tmp/cycle.log")"
	fi
else
	failed "tests/load/cycle_store.kh" "$(cat "$tmp/cycle_store.err")"
fi

# fetch со словарём заголовков из store, пока другие запросы меняют словарь:
# строки запроса собираются под блокировкой store, поэтому заголовки каждого
# запроса — одного поколения (раньше словарь читался уже без блокировки).
fs_port=$((HTTP_PORT + 3))
fs_up=$((HTTP_PORT + 4))
if ! command -v python3 >/dev/null; then
	echo "пропуск fetch со словарём из store: нет python3"
elif "$KHC" -o "$tmp/fetch_store" tests/load/fetch_store.kh >"$tmp/fetch_store.err" 2>&1; then
	python3 tests/load/generations.py "$fs_up" &
	fs_up_pid=$!
	PORT=$fs_port THREADS=4 "$tmp/fetch_store" 2>/dev/null &
	fs_pid=$!
	for _ in $(seq 100); do
		curl -s -o /dev/null "http://127.0.0.1:$fs_port/gen" && break
		sleep 0.05
	done
	for _ in $(seq 100); do
		(exec 3<>"/dev/tcp/127.0.0.1/$fs_up") 2>/dev/null && break
		sleep 0.05
	done
	fs_url="http://127.0.0.1:$fs_port"
	curl -s -o /dev/null -X POST "$fs_url/churn"
	# по соединению на curl: писатели — 8 × 75 запросов, fetch — 16 × 40
	fs_pids=()
	for _ in $(seq 8); do
		curl -s -X POST $(printf "$fs_url/churn %.0s" $(seq 75)) >/dev/null &
		fs_pids+=($!)
	done
	for i in $(seq 16); do
		curl -s -w '\n' $(printf "$fs_url/relay?port=$fs_up %.0s" $(seq 40)) >"$tmp/relay.$i" &
		fs_pids+=($!)
	done
	wait "${fs_pids[@]}"
	r="$(cat "$tmp"/relay.* | grep -c '^200 ok$') $(curl -s "$fs_url/gen")"
	kill "$fs_pid" "$fs_up_pid"
	wait "$fs_pid" "$fs_up_pid" 2>/dev/null
	if [[ "$r" == "640 601" ]]; then
		http_ok
	else
		failed "http: fetch со словарём заголовков из store" "ожидалось «640 601», получено «$r»; не ok: $(cat "$tmp"/relay.* | grep -v '^200 ok$' | head -3)"
	fi
else
	failed "tests/load/fetch_store.kh" "$(cat "$tmp/fetch_store.err")"
fi

# Загрузка store (lib/gc.kh, __store_boot): начальные значения глобальных и
# KHRIP_DATA строятся в арене загрузки, в store остаётся только копия. С
# KHRIP_GC_VERIFY=1 обход от корней подтверждает: после загрузки и после
# восстановления каждый указатель графа store — в STORE или DATA. Снимок khc 0.12
# восстанавливается и сохраняется снова тем же файлом; снимок в 50 МБ — тоже, а
# память после загрузки меньше половины пика: текст файла и разобранное значение
# уходят вместе с ареной.
bs_port=$((HTTP_PORT + 5))
bs_url="http://127.0.0.1:$bs_port"
bs_verify() {
	grep -q "^khrip: gc verify ($1): 6 roots, [0-9]* objects in STORE, every pointer in STORE or DATA$" "$tmp/boot_store.log"
}
# bs_start <файл>: сервер с KHRIP_DATA=<файл>; ждёт конца загрузки
bs_start() {
	PORT=$bs_port THREADS=2 KHRIP_GC_VERIFY=1 KHRIP_DATA="$1" "$tmp/boot_store" 2>"$tmp/boot_store.log" &
	bs_pid=$!
	for _ in $(seq 600); do
		curl -s -o /dev/null "$bs_url/summary" && return
		sleep 0.05
	done
}
# SIGTERM сохраняет store
bs_stop() {
	kill -TERM "$bs_pid"
	wait "$bs_pid" 2>/dev/null
}
if "$KHC" -o "$tmp/boot_store" tests/load/boot_store.kh >"$tmp/boot_store.err" 2>&1; then
	cp tests/load/boot_store.v012.json "$tmp/v012.json"
	bs_start "$tmp/v012.json"
	r=$(curl -s "$bs_url/summary")
	bs_stop
	if [[ "$r" == "12 12 3 1000 998001 filled 12 item-11 привет, мир" ]] && bs_verify boot && bs_verify restore && cmp -s "$tmp/v012.json" tests/load/boot_store.v012.json; then
		http_ok
	else
		failed "http: снимок store khc 0.12" "ответ «$r»; журнал: $(cat "$tmp/boot_store.log"); сохранено: $(head -c 300 "$tmp/v012.json")"
	fi

	rm -f "$tmp/big.json"
	bs_start "$tmp/big.json"
	curl -s -o /dev/null -X POST "$bs_url/fill/180000"
	bs_stop
	cp "$tmp/big.json" "$tmp/big.orig"
	bs_start "$tmp/big.json"
	# VmHWM — пик памяти (загрузка), VmRSS — после неё; в КБ
	read -r hwm rss < <(awk '/^VmHWM:|^VmRSS:/ { printf "%s ", $2 }' "/proc/$bs_pid/status")
	r=$(curl -s "$bs_url/summary")
	bs_stop
	size=$(stat -c %s "$tmp/big.orig")
	if [[ "$r" == "180000 180000 540 1000 998001 filled 180000 item-179999 привет, мир" ]] && ((size > 50000000 && rss * 2 < hwm)) && bs_verify restore && cmp -s "$tmp/big.json" "$tmp/big.orig"; then
		http_ok
	else
		failed "http: восстановление 50 МБ" "ответ «$r», файл $size Б, пик $hwm КБ, после загрузки $rss КБ; журнал: $(cat "$tmp/boot_store.log")"
	fi
	rm -f "$tmp/big.json" "$tmp/big.orig"
else
	failed "tests/load/boot_store.kh" "$(cat "$tmp/boot_store.err")"
fi

# Границы UTF-8 (docs/design/v0.13-utf8.md, §2). Снимок KHRIP_DATA с
# неправильными байтами, суррогатом в WTF-8 (так писала v0.12) и одиноким
# \uD800 читается мягко: 6 замен на U+FFFD, одна строка в журнале, сервер
# работает; сохранённый снимок — правильный UTF-8, и второй запуск молчит.
# Тело и параметр с неправильным UTF-8 — 400, ответ -> str — с charset.
u8_port=$((HTTP_PORT + 6))
if "$KHC" -o "$tmp/utf8_store" tests/load/utf8_store.kh >"$tmp/utf8_store.err" 2>&1; then
	printf '{"notes":{"a":{"title":"x\xFFy"},"b":{"title":"\xED\xA0\x80"},"c":{"title":"\\uD800\\u0041"},"d\xFE":{"title":"ok"}}}' >"$tmp/utf8.json"
	u8_url="http://127.0.0.1:$u8_port"
	u8_start() {
		PORT=$u8_port KHRIP_DATA="$tmp/utf8.json" "$tmp/utf8_store" 2>"$tmp/utf8.$1.log" &
		u8_pid=$!
		for _ in $(seq 100); do
			curl -s -o /dev/null "$u8_url/keys" && break
			sleep 0.05
		done
	}
	u8_start 1
	r=$(curl -s -i "$u8_url/title/a" | tr -d '\r')
	expect_count "UTF-8: снимок, неправильный байт" "$r" $'^x\xEF\xBF\xBDy$' 1
	expect_count "UTF-8: ответ -> str с charset" "$r" "^Content-Type: text/plain; charset=utf-8$" 1
	r="$(curl -s "$u8_url/notes/b") $(curl -s "$u8_url/notes/c") $(curl -s "$u8_url/keys")"
	expect_count "UTF-8: снимок, WTF-8, суррогат и ключ" "$r" '^{"title":"���"} {"title":"�A"} \["a","b","c","d�"\]$' 1
	r=$(curl -s -w ' %{http_code}' -X PUT "$u8_url/notes/e" --data-binary $'{"title":"\xff"}')
	expect_count "UTF-8: тело с неправильным байтом" "$r" '^invalid JSON body: title: invalid UTF-8 400$' 1
	r=$(curl -s -w '%{http_code}' -X PUT "$u8_url/notes/e" --data-binary $'\xef\xbb\xbf{"title":"\xd0\xbe\xd0\xba"}')
	r="$r $(curl -s "$u8_url/notes/e") $(curl -s -w ' %{http_code}' "$u8_url/notes/%D0")"
	expect_count "UTF-8: BOM, параметр пути" "$r" "^204 {\"title\":\"ок\"} parameter 'id' is not valid UTF-8 400$" 1
	kill -TERM "$u8_pid"
	wait "$u8_pid" 2>/dev/null
	expect_count "UTF-8: одна строка о заменах" "$(cat "$tmp/utf8.1.log")" "^khrip: KHRIP_DATA: 6 invalid UTF-8 sequences in .*utf8.json replaced with U+FFFD$" 1
	if python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$tmp/utf8.json" 2>/dev/null; then
		http_ok
	else
		failed "http: UTF-8: снимок после сохранения" "$(od -c "$tmp/utf8.json" | head)"
	fi
	u8_start 2
	r="$(curl -s "$u8_url/title/a") $(curl -s "$u8_url/notes/e")"
	kill -TERM "$u8_pid"
	wait "$u8_pid" 2>/dev/null
	expect_count "UTF-8: второй запуск" "$r" '^x�y {"title":"ок"}$' 1
	expect_count "UTF-8: второй запуск без замен" "$(cat "$tmp/utf8.2.log")" "replaced with U+FFFD" 0
else
	failed "tests/load/utf8_store.kh" "$(cat "$tmp/utf8_store.err")"
fi

# Четыре потока на общей блокировке store работают с одними длинными строками
# (tests/load/text_threads.kh): ответы — те же, что у одного потока без кэша
# строк, и с кэшем, и в его проверочном режиме (stress паникует при ошибке кэша).
tt_port=$((HTTP_PORT + 7))
if "$KHC" -o "$tmp/text_threads" tests/load/text_threads.kh >"$tmp/text_threads.err" 2>&1; then
	tt_url="http://127.0.0.1:$tt_port"
	for k in 0 1 2; do
		for s in $(seq 40); do
			echo "$tt_url/work/$k/$s"
		done
	done >"$tmp/tt.urls"
	tt_run() {
		PORT=$tt_port THREADS=$1 KHRIP_STRCACHE=$2 "$tmp/text_threads" 2>/dev/null &
		tt_pid=$!
		for _ in $(seq 100); do
			curl -s -o /dev/null -X POST "$tt_url/init" && break
			sleep 0.05
		done
		xargs -P "$3" -n 1 curl -s <"$tmp/tt.urls" | sort >"$tmp/tt.$4"
		kill "$tt_pid"
		wait "$tt_pid" 2>/dev/null
	}
	tt_run 1 off 1 off
	tt_run 4 "" 16 on
	tt_run 4 stress 16 stress
	if [[ $(wc -l <"$tmp/tt.off") == 120 ]] && cmp -s "$tmp/tt.off" "$tmp/tt.on" && cmp -s "$tmp/tt.off" "$tmp/tt.stress"; then
		http_ok
	else
		failed "http: строки в 4 потоках" "$(diff "$tmp/tt.off" "$tmp/tt.on" | head -5; diff "$tmp/tt.off" "$tmp/tt.stress" | head -5)"
	fi
else
	failed "tests/load/text_threads.kh" "$(cat "$tmp/text_threads.err")"
fi
