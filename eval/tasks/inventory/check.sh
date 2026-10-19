#!/usr/bin/env bash
# Проверка склада и заказов; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "add" 201 '"sku":"APL-1" && "name":"Apple" && "stock":10' "${J[@]}" -X POST $U/items -d '{"sku":"APL-1","name":"Apple","stock":10}'
check "add 2" 201 '"sku":"BAN" && "stock":2' "${J[@]}" -X POST $U/items -d '{"sku":"BAN","name":"Banana","stock":2}'
check "add 3" 201 '"sku":"0-CHERRY" && "stock":0' "${J[@]}" -X POST $U/items -d '{"sku":"0-CHERRY","name":"Cherry","stock":0}'
check "duplicate" 409 '' "${J[@]}" -X POST $U/items -d '{"sku":"BAN","name":"Other","stock":1}'
check "lower sku" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"ban2","name":"x","stock":1}'
check "short sku" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"AB","name":"x","stock":1}'
check "long sku" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"ABCDEFGHIJKLMNOPQRSTU","name":"x","stock":1}'
check "sku space" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"AB C","name":"x","stock":1}'
check "blank name" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"DDD","name":" ","stock":1}'
check "negative stock" 400 '' "${J[@]}" -X POST $U/items -d '{"sku":"DDD","name":"x","stock":-1}'
check "list" 200 '' $U/items
jtest "list sorted" "[i['sku'] for i in j] == ['0-CHERRY', 'APL-1', 'BAN']"
check "restock" 200 '"sku":"0-CHERRY" && "stock":5' "${J[@]}" -X POST $U/items/0-CHERRY/restock -d '{"amount":5}'
check "restock zero" 400 '' "${J[@]}" -X POST $U/items/BAN/restock -d '{"amount":0}'
check "restock unknown" 404 '' "${J[@]}" -X POST $U/items/NOPE/restock -d '{"amount":1}'
check "order" 201 '"id":1 && "status":"placed" && "total_qty":5 && "lines":\[' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"APL-1","qty":3},{"sku":"BAN","qty":2}]}'
jtest "order lines" "j['lines'] == [{'sku': 'APL-1', 'qty': 3}, {'sku': 'BAN', 'qty': 2}]"
check "stock taken" 200 '"stock":7' $U/items
jtest "stock after order" "{i['sku']: i['stock'] for i in j} == {'0-CHERRY': 5, 'APL-1': 7, 'BAN': 0}"
check "not enough" 409 '' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"APL-1","qty":1},{"sku":"BAN","qty":1}]}'
check "same sku adds up" 409 '' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"0-CHERRY","qty":3},{"sku":"0-CHERRY","qty":3}]}'
check "nothing changed" 200 '' $U/items
jtest "stock unchanged" "{i['sku']: i['stock'] for i in j} == {'0-CHERRY': 5, 'APL-1': 7, 'BAN': 0}"
check "no lines" 400 '' "${J[@]}" -X POST $U/orders -d '{"lines":[]}'
check "zero qty" 400 '' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"APL-1","qty":0}]}'
check "unknown sku" 404 '' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"NOPE","qty":1}]}'
check "order 2" 201 '"id":2 && "total_qty":4' "${J[@]}" -X POST $U/orders -d '{"lines":[{"sku":"0-CHERRY","qty":2},{"sku":"0-CHERRY","qty":2}]}'
check "cancel" 200 '"id":1 && "status":"cancelled"' -X POST $U/orders/1/cancel
check "cancel again" 409 '' -X POST $U/orders/1/cancel
check "cancel unknown" 404 '' -X POST $U/orders/99/cancel
check "stock returned" 200 '' $U/items
jtest "stock after cancel" "{i['sku']: i['stock'] for i in j} == {'0-CHERRY': 1, 'APL-1': 10, 'BAN': 2}"
check "orders" 200 '' $U/orders
jtest "orders all" "[(o['id'], o['status']) for o in j] == [(1, 'cancelled'), (2, 'placed')]"
check "orders placed" 200 '' "$U/orders?status=placed"
jtest "orders filtered" "[o['id'] for o in j] == [2]"
check "orders bad status" 400 '' "$U/orders?status=lost"

# Одновременно: 40 заказов по 1 при запасе 15 — ровно 15 проходят.
check "item for race" 201 '' "${J[@]}" -X POST $U/items -d '{"sku":"RACE","name":"Race","stock":15}'
codes=$(seq 40 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
	-X POST $U/orders -d '{"lines":[{"sku":"RACE","qty":1}]}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
[[ "$codes" == " 15 201; 25 409;" ]] || { echo "FAIL concurrent orders: $codes"; fails=$((fails + 1)); }
total=$((total + 1))
check "race stock" 200 '' $U/items
jtest "race stock zero" "[i['stock'] for i in j if i['sku'] == 'RACE'] == [0]"
finish
