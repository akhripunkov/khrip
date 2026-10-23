#!/usr/bin/env bash
# После перезапуска: данные в базе. $STATE — номера из check.sh.
. "$(dirname "$0")/../../lib.sh"
read -r p2 <"$STATE"
check "kept product" 200 "\"id\":$p2 && \"price\":95 && \"stock\":4" $U/products/$p2
jtest "kept tags" "j['tags'] == ['red', 'juicy']"
check "kept orders" 200 '' $U/customers/r@x.io/orders
jtest "kept count" "len(j) == 20"
check "kept stats" 200 '' $U/stats/categories
jtest "kept revenue" "j[0] == {'category': 'Toys', 'products': 1, 'units_sold': 20, 'revenue': 20000}"
check "new category" 201 '"name":"Books"' "${J[@]}" -X POST $U/categories -d '{"name":"Books"}'
# длина — в символах: 30 букв кириллицы — 60 байт
cyr=$(printf 'я%.0s' $(seq 30))
check "cyrillic category" 201 "\"name\":\"$cyr\"" "${J[@]}" -X POST $U/categories -d "{\"name\":\"$cyr\"}"
finish
