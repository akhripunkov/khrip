# Свой TLS 1.3: криптография на случайных данных, проверка цепочек
# сертификатов, рукопожатия с OpenSSL (шифры, RSA и ECDSA, HelloRetryRequest,
# отказы), keep-alive, большие тела и KeyUpdate. Подключается из tests/run.sh
# (использует KHC, tmp, failed, http_ok, expect_count). Нужны openssl, python3,
# для случайных данных — модуль cryptography.

TLS_PORT=${TLS_PORT:-18190}

if ! command -v openssl >/dev/null || ! command -v python3 >/dev/null; then
	echo "пропуск TLS-тестов: нет openssl или python3"
	return 0
fi

tls_dir="$tmp/tls"
mkdir -p "$tls_dir/pki"
if ! tests/tls/gen.sh "$tls_dir/pki" 2>"$tls_dir/gen.err"; then
	failed "tls" "сертификаты не создались: $(cat "$tls_dir/gen.err")"
	return 0
fi
pki="$tls_dir/pki"

for prog in vectors chain client; do
	if ! "$KHC" -o "$tls_dir/$prog" "tests/tls/$prog.kh" 2>"$tls_dir/$prog.err"; then
		failed "tls" "$prog не скомпилировался: $(cat "$tls_dir/$prog.err")"
		return 0
	fi
done

# криптография против Python cryptography
if python3 -c "import cryptography" 2>/dev/null; then
	python3 tests/tls/vectors.py "$RANDOM" >"$tls_dir/vectors.txt"
	r=$("$tls_dir/vectors" "$tls_dir/vectors.txt")
	expect_count "tls: AES-GCM, ChaCha20-Poly1305, RSA, ECDSA, ECDH, X25519" "$r" " 0 failed$" 1
fi

# цепочки сертификатов
cat "$pki/leafclient.pem" "$pki/inter.pem" >"$pki/chain_client.pem"
cat "$pki/leafexpired.pem" "$pki/inter.pem" >"$pki/chain_expired.pem"
cat "$pki/leafnc.pem" "$pki/nc.pem" >"$pki/chain_nc.pem"
chain() {
	SSL_CERT_FILE="$pki/${3:-root}.pem" "$tls_dir/chain" "$pki/$1" "$2"
}
expect_count "tls: цепочка ECDSA" "$(chain chain_ec.pem test.local)" "^test.local: ok$" 1
expect_count "tls: цепочка RSA" "$(chain chain_rsa.pem test.local)" "^test.local: ok$" 1
expect_count "tls: *.wild.local" "$(chain chain_ec.pem a.wild.local)" ": ok$" 1
expect_count "tls: шаблон — одна метка" "$(chain chain_ec.pem a.b.wild.local)" "another name" 1
expect_count "tls: шаблон не покрывает сам домен" "$(chain chain_ec.pem wild.local)" "another name" 1
expect_count "tls: адрес IP" "$(chain chain_ec.pem 127.0.0.1)" ": ok$" 1
expect_count "tls: чужое имя" "$(chain chain_ec.pem other.local)" "another name" 1
expect_count "tls: нет промежуточного" "$(chain leaf.pem test.local)" "not signed by a trusted authority" 1
expect_count "tls: сертификат для клиентов" "$(chain chain_client.pem test.local)" "not for TLS servers" 1
expect_count "tls: просроченный" "$(chain chain_expired.pem test.local)" "expired" 1
expect_count "tls: nameConstraints разрешает" "$(chain chain_nc.pem allowed.local)" ": ok$" 1
expect_count "tls: nameConstraints запрещает" "$(chain chain_nc.pem test.local)" "outside what the certificate authority may sign" 1
expect_count "tls: чужой корень с тем же именем" "$(chain chain_ec.pem test.local other)" "not signed by a trusted authority" 1

# рукопожатия с openssl s_server
srv_port=$((TLS_PORT + 1))
SSL_CERT_FILE="$pki/root.pem" PORT=$TLS_PORT THREADS=1 "$tls_dir/client" 2>/dev/null &
client_pid=$!
for _ in $(seq 100); do
	curl -s -o /dev/null "http://127.0.0.1:$TLS_PORT/" && break
	sleep 0.02
done
s_server() {
	(cd "$pki" && exec openssl s_server -accept "$srv_port" -www -quiet "$@") >/dev/null 2>&1 &
	s_pid=$!
	for _ in $(seq 100); do
		(exec 3<>"/dev/tcp/127.0.0.1/$srv_port") 2>/dev/null && break
		sleep 0.02
	done
}
handshake() {
	local name=$1 want=$2
	shift 2
	s_server "$@"
	r=$(curl -s "http://127.0.0.1:$TLS_PORT/get?url=https://127.0.0.1:$srv_port/")
	kill "$s_pid"
	wait "$s_pid" 2>/dev/null
	expect_count "tls: $name" "$r" "$want" 1
}
ec=(-cert leaf.pem -key leaf.key -cert_chain inter.pem)
# первым: потом этот сертификат будет в кеше проверенных цепочек клиента
handshake "сервер без промежуточного" "not signed by a trusted authority" -tls1_3 -cert leaf.pem -key leaf.key
handshake "AES-128-GCM" "^200 TLS_AES_128_GCM_SHA256$" -tls1_3 "${ec[@]}" -ciphersuites TLS_AES_128_GCM_SHA256
handshake "AES-256-GCM" "^200 TLS_AES_256_GCM_SHA384$" -tls1_3 "${ec[@]}" -ciphersuites TLS_AES_256_GCM_SHA384
handshake "ChaCha20-Poly1305" "^200 TLS_CHACHA20_POLY1305_SHA256$" -tls1_3 "${ec[@]}" -ciphersuites TLS_CHACHA20_POLY1305_SHA256
handshake "сертификат RSA (подпись PSS)" "^200 TLS_" -tls1_3 -cert leafrsa.pem -key leafrsa.key -cert_chain inter.pem
handshake "HelloRetryRequest: P-256 вместо X25519" "^200 TLS_" -tls1_3 "${ec[@]}" -groups P-256
handshake "просроченный сертификат сервера" "expired" -tls1_3 -cert leafexpired.pem -key leaf.key -cert_chain inter.pem
handshake "сервер только с TLS 1.2" "protocol version" -tls1_2 "${ec[@]}"
handshake "нет общей группы" "handshake failure" -tls1_3 "${ec[@]}" -groups X448

# KeyUpdate от сервера посреди соединения: s_server по команде «K» из stdin
mkfifo "$tls_dir/ku"
(cd "$pki" && exec openssl s_server -accept "$srv_port" -tls1_3 "${ec[@]}" <"$tls_dir/ku") >/dev/null 2>&1 &
s_pid=$!
exec 7>"$tls_dir/ku"
for _ in $(seq 100); do
	(exec 3<>"/dev/tcp/127.0.0.1/$srv_port") 2>/dev/null && break
	sleep 0.02
done
curl -s "http://127.0.0.1:$TLS_PORT/get?url=https://127.0.0.1:$srv_port/" >"$tls_dir/ku.out" &
curl_pid=$!
sleep 0.5
printf 'K\n' >&7
sleep 0.3
printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nafter' >&7
wait "$curl_pid"
exec 7>&-
kill "$s_pid" 2>/dev/null
wait "$s_pid" 2>/dev/null
expect_count "tls: KeyUpdate от сервера" "$(cat "$tls_dir/ku.out")" "^200 5 bytes$" 1

# keep-alive, большие тела
python3 tests/tls/https_server.py "$pki/chain_ec.pem" "$pki/leaf.key" "$srv_port" 2>/dev/null &
py_pid=$!
for _ in $(seq 100); do
	(exec 3<>"/dev/tcp/127.0.0.1/$srv_port") 2>/dev/null && break
	sleep 0.05
done
url="https://127.0.0.1:$srv_port"
expect_count "tls: 10 запросов — одно соединение" "$(curl -s "http://127.0.0.1:$TLS_PORT/seq?n=10&url=$url")" "^connections: 1$" 1
expect_count "tls: ответ 2 МБ" "$(curl -s "http://127.0.0.1:$TLS_PORT/get?url=$url/big=2000000")" "^200 2000000 bytes$" 1
expect_count "tls: тело запроса 300 КБ" "$(curl -s "http://127.0.0.1:$TLS_PORT/post?size=300000&url=$url")" "^200 300000 abab abab$" 1
kill "$py_pid" "$client_pid"
wait "$py_pid" "$client_pid" 2>/dev/null
