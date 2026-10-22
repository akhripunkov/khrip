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
