#!/usr/bin/env bash
# Проверка счетов и переводов в PostgreSQL; две копии сервера: $U и $U2.
# Номера берутся из ответов: неудачная вставка может занять номер в последовательности.
. "$(dirname "$0")/../../lib.sh"
U2=${U2:-$U}

check "open" 201 '"owner":"ann" && "currency":"USD" && "balance":0' "${J[@]}" -X POST $U/accounts -d '{"owner":"ann","currency":"USD"}'
a=$(jval "j['id']")
check "open 2" 201 '"currency":"USD"' "${J[@]}" -X POST $U2/accounts -d '{"owner":"bob","currency":"USD"}'
b=$(jval "j['id']")
check "open eur" 201 '"currency":"EUR"' "${J[@]}" -X POST $U/accounts -d '{"owner":"cid","currency":"EUR"}'
c=$(jval "j['id']")
same "distinct ids" "$(tr ' ' '\n' <<<"$a $b $c" | sort -u | grep -c '^[0-9]')" 3
check "blank owner" 400 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"  ","currency":"USD"}'
check "bad currency" 400 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"x","currency":"usd"}'
check "no currency" 400 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"x"}'
check "get" 200 "\"id\":$b && \"owner\":\"bob\" && \"balance\":0" $U/accounts/$b
check "get other copy" 200 "\"id\":$a && \"owner\":\"ann\"" $U2/accounts/$a
check "get missing" 404 '' $U/accounts/999999
check "deposit" 200 "\"id\":$a && \"balance\":1000" "${J[@]}" -X POST $U/accounts/$a/deposit -d '{"amount":1000}'
check "deposit eur" 200 '"balance":500' "${J[@]}" -X POST $U2/accounts/$c/deposit -d '{"amount":500}'
check "deposit zero" 400 '' "${J[@]}" -X POST $U/accounts/$a/deposit -d '{"amount":0}'
check "deposit missing" 404 '' "${J[@]}" -X POST $U/accounts/999999/deposit -d '{"amount":5}'
check "transfer" 201 "\"from\":$a && \"to\":$b && \"amount\":300 && \"created_at\":$ISO" \
	"${J[@]}" -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":300}"
t1=$(jval "j['id']")
check "balance from" 200 '"balance":700' $U2/accounts/$a
check "balance to" 200 '"balance":300' $U2/accounts/$b
check "transfer back" 201 "\"from\":$b && \"to\":$a && \"amount\":100" "${J[@]}" -X POST $U2/transfers -d "{\"from\":$b,\"to\":$a,\"amount\":100}"
t2=$(jval "j['id']")
check "insufficient" 409 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":$b,\"to\":$a,\"amount\":201}"
check "unchanged" 200 '"balance":200' $U/accounts/$b
check "same account" 400 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":$a,\"to\":$a,\"amount\":1}"
check "zero amount" 400 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":0}"
check "unknown to" 404 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":$a,\"to\":999999,\"amount\":1}"
check "unknown from" 404 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":999999,\"to\":$a,\"amount\":1}"
check "currencies" 422 '' "${J[@]}" -X POST $U/transfers -d "{\"from\":$a,\"to\":$c,\"amount\":1}"

# Ключ идемпотентности: повтор не переводит деньги снова.
check "keyed" 201 '"amount":50' "${J[@]}" -H 'Idempotency-Key: k-1' -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":50}"
t3=$(jval "j['id']")
check "keyed again" 201 "\"id\":$t3 && \"amount\":50" "${J[@]}" -H 'Idempotency-Key: k-1' -X POST $U2/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":50}"
check "keyed once" 200 '"balance":750' $U/accounts/$a
check "key other body" 422 '' "${J[@]}" -H 'Idempotency-Key: k-1' -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":51}"
check "key too long" 400 '' "${J[@]}" -H "Idempotency-Key: $(printf 'k%.0s' $(seq 65))" -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":1}"

# История: новые первыми, limit и before.
check "history" 200 '' $U/accounts/$a/transfers
jtest "history order" "[t['id'] for t in j] == [$t3, $t2, $t1]"
check "history limit" 200 '' "$U/accounts/$a/transfers?limit=2"
jtest "history limit 2" "[t['id'] for t in j] == [$t3, $t2]"
check "history before" 200 '' "$U2/accounts/$a/transfers?limit=2&before=$t2"
jtest "history page 2" "[t['id'] for t in j] == [$t1]"
check "history empty" 200 '^\[\]$' $U/accounts/$c/transfers
check "history bad limit" 400 '' "$U/accounts/$a/transfers?limit=0"
check "history big limit" 400 '' "$U/accounts/$a/transfers?limit=101"
check "history bad before" 400 '' "$U/accounts/$a/transfers?before=x"
check "history missing" 404 '' $U/accounts/999999/transfers
check "stats" 200 '' $U/stats
jtest "stats values" "j == {'accounts': 3, 'transfers': 3, 'balances': {'USD': 1000, 'EUR': 500, 'GBP': 0}}"

# Одновременно, на двух копиях: 60 переводов по 10 со счёта с 300 — ровно 30.
check "race account" 201 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"dan","currency":"GBP"}'
d=$(jval "j['id']")
check "race account 2" 201 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"eve","currency":"GBP"}'
e=$(jval "j['id']")
check "race deposit" 200 '"balance":300' "${J[@]}" -X POST $U/accounts/$d/deposit -d '{"amount":300}'
same "concurrent transfers" "$(race 60 30 /transfers "${J[@]}" -X POST -d "{\"from\":$d,\"to\":$e,\"amount\":10}")" " 30 201; 30 409;"
check "after race from" 200 '"balance":0' $U/accounts/$d
check "after race to" 200 '"balance":300' $U2/accounts/$e
# Встречные переводы одновременно: ни один не теряется, взаимоблокировка не
# превращается в ошибку.
check "cross deposit" 200 '"balance":100' "${J[@]}" -X POST $U/accounts/$d/deposit -d '{"amount":100}'
out=$(mktemp -d)
race 40 20 /transfers "${J[@]}" -X POST -d "{\"from\":$e,\"to\":$d,\"amount\":1}" >"$out/a" &
race 40 20 /transfers "${J[@]}" -X POST -d "{\"from\":$d,\"to\":$e,\"amount\":1}" >"$out/b" &
wait
same "crossing transfers" "$(cat "$out/a" "$out/b")" " 40 201; 40 201;"
rm -rf "$out"
check "crossing 1" 200 '"balance":100' $U/accounts/$d
check "crossing 2" 200 '"balance":300' $U2/accounts/$e
# 200 одновременных пополнений по 1 — ни одно не теряется.
same "concurrent deposits" "$(race 200 40 /accounts/$d/deposit "${J[@]}" -X POST -d '{"amount":1}')" " 200 200;"
check "deposits" 200 '"balance":300' $U/accounts/$d
# Один ключ идемпотентности одновременно: один перевод, у всех один ответ.
same "concurrent key" "$(race 20 20 /transfers "${J[@]}" -H 'Idempotency-Key: same' -X POST -d "{\"from\":$d,\"to\":$e,\"amount\":7}")" " 20 201;"
check "concurrent key once" 200 '"balance":293' $U2/accounts/$d
check "stats after" 200 '' $U/stats
jtest "stats sum" "j['balances'] == {'USD': 1000, 'EUR': 500, 'GBP': 600} and j['accounts'] == 5 and j['transfers'] == 3 + 30 + 80 + 1"
echo "$a $b $t3" >"${STATE:-/dev/null}"
finish
