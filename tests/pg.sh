# Клиент PostgreSQL: временный сервер с паролями SCRAM, MD5 и открытым, с TLS
# на тестовых сертификатах; вывод tests/pg/*.kh сравнивается с .out.
# Подключается из tests/run.sh (использует KHC, tmp, failed). Нужен PostgreSQL
# (initdb, pg_ctl, psql); под root сервер запускается от пользователя postgres.

PG_PORT=${PG_PORT:-18290}

pg_bin=$(dirname "$(command -v pg_ctl 2>/dev/null || ls -d /usr/lib/postgresql/*/bin/pg_ctl 2>/dev/null | sort -V | tail -1)")
if [[ ! -x "$pg_bin/initdb" ]] || ! command -v openssl >/dev/null; then
	echo "пропуск тестов PostgreSQL: нет initdb или openssl"
	return 0
fi
as_pg=()
if [[ $(id -u) == 0 ]]; then
	if ! id postgres >/dev/null 2>&1; then
		echo "пропуск тестов PostgreSQL: под root нужен пользователь postgres"
		return 0
	fi
	as_pg=(runuser -u postgres --)
fi

# каталог сервера должен быть доступен его пользователю: не внутри $tmp
pg_dir=$(mktemp -d /var/tmp/khrip-pgtest.XXXXXX)
pg_data="$pg_dir/data"
mkdir -p "$tmp/pg/pki"
tests/tls/gen.sh "$tmp/pg/pki" 2>/dev/null
cp "$tmp/pg/pki/chain_ec.pem" "$pg_dir/server.crt"
cp "$tmp/pg/pki/leaf.key" "$pg_dir/server.key"
chmod 600 "$pg_dir/server.key"
echo postgres >"$pg_dir/pw"
[[ ${#as_pg[@]} -gt 0 ]] && chown -R postgres "$pg_dir"

pg_stop() {
	"${as_pg[@]}" "$pg_bin/pg_ctl" -D "$pg_data" -m immediate stop >/dev/null 2>&1
	rm -rf "${pg_dir:?}"
}

if ! "${as_pg[@]}" "$pg_bin/initdb" -D "$pg_data" -U postgres --pwfile="$pg_dir/pw" -A scram-sha-256 >"$tmp/pg/initdb.log" 2>&1; then
	failed "pg" "initdb: $(tail -5 "$tmp/pg/initdb.log")"
	pg_stop
	return 0
fi
cat >"$pg_data/pg_hba.conf" <<X
local all all trust
host all u_md5 127.0.0.1/32 md5
host all u_plain 127.0.0.1/32 password
host all all 127.0.0.1/32 scram-sha-256
X
if ! "${as_pg[@]}" "$pg_bin/pg_ctl" -D "$pg_data" -l "$pg_dir/log" -w -o "-p $PG_PORT -k $pg_dir -c listen_addresses=127.0.0.1 -c ssl=on -c ssl_cert_file=$pg_dir/server.crt -c ssl_key_file=$pg_dir/server.key" start >/dev/null 2>&1; then
	failed "pg" "сервер не запустился: $(tail -5 "$pg_dir/log" 2>/dev/null)"
	pg_stop
	return 0
fi
"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres >/dev/null 2>&1 <<'X'
create database khrip_test;
create user u_scram password 'pw-u_scram' superuser;
create user u_plain password 'pw-u_plain';
set password_encryption = 'md5';
create user u_md5 password 'pw-u_md5';
grant all on database khrip_test to u_md5, u_plain;
X

for src in tests/pg/*.kh; do
	name=$(basename "$src" .kh)
	if grep -q '^test "' "$src"; then
		# программа с блоками test: khc test на своей пустой базе (строка
		# проверки после загрузки с KHRIP_GC_VERIFY=1 — не часть вывода)
		"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres -c "create database t_$name" >/dev/null 2>&1
		DATABASE_URL="postgres://u_scram:pw-u_scram@127.0.0.1:$PG_PORT/t_$name?sslmode=disable" "$KHC" test "$src" 2>&1 | grep -v '^khrip: gc verify (boot): ' >"$tmp/pg/$name.out"
		if ! diff -u "tests/pg/$name.out" "$tmp/pg/$name.out" >"$tmp/pg/$name.diff"; then
			failed "$src" "вывод тестов отличается от ожидаемого"
			cat "$tmp/pg/$name.diff"
			continue
		fi
		pass=$((pass + 1))
		continue
	fi
	if ! "$KHC" -o "$tmp/pg/$name" "$src" >"$tmp/pg/$name.err" 2>&1; then
		failed "$src" "не скомпилировалось:"$'\n'"$(cat "$tmp/pg/$name.err")"
		continue
	fi
	"$tmp/pg/$name" "$PG_PORT" "$tmp/pg/pki" >"$tmp/pg/$name.out" 2>&1
	if ! diff -u "tests/pg/$name.out" "$tmp/pg/$name.out" >"$tmp/pg/$name.diff"; then
		failed "$src" "вывод отличается от ожидаемого"
		cat "$tmp/pg/$name.diff"
		continue
	fi
	pass=$((pass + 1))
done

# Урок 7 учебника и ответ к нему (docs/tutorial/db): khc test на своей базе.
for src in docs/tutorial/db/*.kh docs/tutorial/db/answers/*.kh; do
	name=tut_$(basename "$src" .kh)
	"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres -c "create database $name" >/dev/null 2>&1
	if DATABASE_URL="postgres://u_scram:pw-u_scram@127.0.0.1:$PG_PORT/$name?sslmode=disable" "$KHC" test "$src" >"$tmp/pg/$name.out" 2>&1; then
		pass=$((pass + 1))
	else
		failed "$src" "$(tail -20 "$tmp/pg/$name.out")"
	fi
done

# khc test, миграция не прошла: временная схема всё равно удалена.
cat >"$tmp/pg/migfail.kh" <<'X'
migration 1 `
CREATE TABLE t (id bigint PRIMARY KEY);
CREATE TABLE t (id bigint PRIMARY KEY);
`
test "never runs" {
    expect true
}
X
"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres -c "create database t_migfail" >/dev/null 2>&1
if DATABASE_URL="postgres://u_scram:pw-u_scram@127.0.0.1:$PG_PORT/t_migfail?sslmode=disable" "$KHC" test "$tmp/pg/migfail.kh" >"$tmp/pg/migfail.out" 2>&1; then
	failed "khc test: failed migration" "khc test passed"
else
	left=$("${as_pg[@]}" "$pg_bin/psql" -tA -h "$pg_dir" -p "$PG_PORT" -U postgres -d t_migfail -c "select count(*) from information_schema.schemata where schema_name like 'khrip_test_%'")
	if [[ $left == 0 ]] && grep -q "migration failed" "$tmp/pg/migfail.out"; then
		pass=$((pass + 1))
	else
		failed "khc test: failed migration" "the test schema was left ($left): $(cat "$tmp/pg/migfail.out")"
	fi
fi

# Корпус правильного SQL: PostgreSQL подтверждает каждый запрос (khc test).
for src in tests/sqlcheck/*.kh; do
	name=$(basename "$src" .kh)
	"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres -c "create database s_$name" >/dev/null 2>&1
	if DATABASE_URL="postgres://u_scram:pw-u_scram@127.0.0.1:$PG_PORT/s_$name?sslmode=disable" "$KHC" test "$src" >"$tmp/pg/s_$name.out" 2>&1; then
		pass=$((pass + 1))
	else
		failed "$src" "PostgreSQL не принял корпус:"$'\n'"$(tail -20 "$tmp/pg/s_$name.out")"
	fi
done

# Очередь повторов tx под одновременными запросами: горячая строка и переводы
# «прочитал — записал». Ни одного 503, счётчик равен числу ответов, деньги не
# теряются и не появляются. Тем временем /label заменяет метки store и
# оставляет мусор: /hit держит метку через тело tx с повторами, пока идут
# сборки store (docs/design/v0.13-store-gc.md §15.2).
race_port=$((PG_PORT + 1))
"${as_pg[@]}" "$pg_bin/psql" -q -h "$pg_dir" -p "$PG_PORT" -U postgres -d postgres -c "create database t_race" >/dev/null 2>&1
if ! "$KHC" -o "$tmp/pg/race" tests/pg/load/race.kh >"$tmp/pg/race.err" 2>&1; then
	failed "tests/pg/load/race.kh" "не скомпилировалось:"$'\n'"$(cat "$tmp/pg/race.err")"
else
	DATABASE_URL="postgres://u_scram:pw-u_scram@127.0.0.1:$PG_PORT/t_race?sslmode=disable" PORT=$race_port THREADS=2 KHRIP_GC_LOG=1 \
		"$tmp/pg/race" 2>"$tmp/pg/race.log" &
	race_pid=$!
	for _ in $(seq 100); do
		curl -s -o /dev/null "http://127.0.0.1:$race_port/total" && break
		sleep 0.1
	done
	url=http://127.0.0.1:$race_port
	# горячая строка 1 и строка 75 (за пределами 63 ключей очереди) вместе с
	# транзакциями на все 80 строк; затем переводы «прочитал — записал»
	seq 60 | xargs -P 4 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST "$url/label/{}" >"$tmp/pg/race.labels" &
	race_lb=$!
	{
		seq 300 | sed "s|.*|$url/hit/1|"
		seq 100 | sed "s|.*|$url/hit/75|"
		seq 20 | sed "s|.*|$url/sweep|"
	} | shuf | xargs -P 32 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST {} >"$tmp/pg/race.hits"
	wait "$race_lb"
	for i in $(seq 300); do
		a=$((RANDOM % 5 + 1)) b=$((RANDOM % 4 + 1))
		((b >= a)) && b=$((b + 1))
		echo "$url/move/$a/$b/$((RANDOM % 300 + 1))"
	done | xargs -P 32 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST {} >"$tmp/pg/race.moves"
	total=$(curl -s "$url/total")
	one=$(curl -s "$url/counter/1")
	kill "$race_pid" 2>/dev/null
	wait "$race_pid" 2>/dev/null
	hits=$(grep -c '^20[04]$' "$tmp/pg/race.hits")
	bad=$(grep -cv '^20[04]$\|^409$' "$tmp/pg/race.moves")
	labels=$(grep -c '^204$' "$tmp/pg/race.labels")
	cycles=$(grep -c '^gc [0-9]* (' "$tmp/pg/race.log")
	# 400 попаданий по одной строке и 20 проходов по 80 строкам
	if [[ $hits == 420 && $bad == 0 && $labels == 60 && $total == '{"n":2000,"balance":5000}' && $one == '{"id":1,"n":320}' ]] && ((cycles >= 2)); then
		pass=$((pass + 1))
	else
		failed "tests/pg/load/race.kh" "успешных /hit и /sweep: $hits из 420, других ответов на /move: $bad, /label: $labels из 60, сборок store: $cycles, итог: $total, строка 1: $one"$'\n'"$(sort "$tmp/pg/race.hits" "$tmp/pg/race.moves" | uniq -c)"$'\n'"$(grep -v '^gc [0-9]' "$tmp/pg/race.log" | tail -5)"
	fi
fi

pg_stop
