#!/usr/bin/env bash
# Проверка банковских счетов; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "open 1" 201 '"id":1 && "owner":"ann" && "balance":0' "${J[@]}" -X POST $U/accounts -d '{"owner":"ann"}'
check "open 2" 201 '"id":2 && "owner":"bob" && "balance":0' "${J[@]}" -X POST $U/accounts -d '{"owner":"bob"}'
check "blank owner" 400 '' "${J[@]}" -X POST $U/accounts -d '{"owner":"  "}'
check "missing owner" 400 '' "${J[@]}" -X POST $U/accounts -d '{}'
check "get" 200 '"id":1 && "owner":"ann" && "balance":0' $U/accounts/1
check "get missing" 404 '' $U/accounts/99
check "deposit" 200 '"id":1 && "balance":1000' "${J[@]}" -X POST $U/accounts/1/deposit -d '{"amount":1000}'
check "deposit zero" 400 '' "${J[@]}" -X POST $U/accounts/1/deposit -d '{"amount":0}'
check "deposit negative" 400 '' "${J[@]}" -X POST $U/accounts/1/deposit -d '{"amount":-5}'
check "deposit missing" 404 '' "${J[@]}" -X POST $U/accounts/99/deposit -d '{"amount":5}'
check "transfer" 201 '"id":1 && "from_id":1 && "to_id":2 && "amount":300 && "created_at":'"$ISO" \
	"${J[@]}" -X POST $U/transfers -d '{"from_id":1,"to_id":2,"amount":300}'
check "balances 1" 200 '"balance":700' $U/accounts/1
check "balances 2" 200 '"balance":300' $U/accounts/2
check "transfer back" 201 '"id":2 && "from_id":2 && "to_id":1 && "amount":100' "${J[@]}" -X POST $U/transfers -d '{"from_id":2,"to_id":1,"amount":100}'
check "insufficient" 409 '' "${J[@]}" -X POST $U/transfers -d '{"from_id":2,"to_id":1,"amount":201}'
check "unchanged" 200 '"balance":200' $U/accounts/2
check "same account" 400 '' "${J[@]}" -X POST $U/transfers -d '{"from_id":1,"to_id":1,"amount":1}'
check "zero amount" 400 '' "${J[@]}" -X POST $U/transfers -d '{"from_id":1,"to_id":2,"amount":0}'
check "unknown to" 404 '' "${J[@]}" -X POST $U/transfers -d '{"from_id":1,"to_id":42,"amount":1}'
check "unknown from" 404 '' "${J[@]}" -X POST $U/transfers -d '{"from_id":42,"to_id":1,"amount":1}'
check "open 3" 201 '"id":3' "${J[@]}" -X POST $U/accounts -d '{"owner":"cid"}'
check "history" 200 '^\[\{[^{}]*"id":2[^{}]*\},\{[^{}]*"id":1[^{}]*\}\]$' $U/accounts/1/transfers
check "history empty" 200 '^\[\]$' $U/accounts/3/transfers
check "history missing" 404 '' $U/accounts/99/transfers

# Одновременно: 60 переводов по 10 со счёта с 300 — ровно 30 проходят.
check "fund 4" 201 '"id":4' "${J[@]}" -X POST $U/accounts -d '{"owner":"dan"}'
check "fund 4 deposit" 200 '"balance":300' "${J[@]}" -X POST $U/accounts/4/deposit -d '{"amount":300}'
codes=$(seq 60 | xargs -P 30 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
	-X POST $U/transfers -d '{"from_id":4,"to_id":3,"amount":10}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
[[ "$codes" == " 30 201; 30 409;" ]] || { echo "FAIL concurrent transfers: $codes"; fails=$((fails + 1)); }
total=$((total + 1))
check "after race 4" 200 '"balance":0' $U/accounts/4
check "after race 3" 200 '"balance":300' $U/accounts/3
# 200 одновременных пополнений по 1 — ни одно не теряется.
seq 200 | xargs -P 40 -I{} curl -s -o /dev/null -H 'Content-Type: application/json' -X POST $U/accounts/3/deposit -d '{"amount":1}'
check "concurrent deposits" 200 '"balance":500' $U/accounts/3
finish
