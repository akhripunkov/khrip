#!/usr/bin/env bash
# Проверка каталога товаров; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

add() {
	check "add $1" 201 "\"id\":$1" "${J[@]}" -X POST $U/products -d "$2"
}
check "create" 201 '"id":1 && "name":"Red Apple" && "category":"fruit" && "price":1.25 && "tags":\["fresh","red"\]' \
	"${J[@]}" -X POST $U/products -d '{"name":"Red Apple","category":"fruit","price":1.25,"tags":["fresh","red"]}'
check "no tags" 201 '"id":2 && "tags":\[\]' "${J[@]}" -X POST $U/products -d '{"name":"Banana","category":"fruit","price":0.5}'
check "int price" 201 '"id":3 && "price":(3|3\.0)\b' "${J[@]}" -X POST $U/products -d '{"name":"Green apple pie","category":"bakery","price":3}'
add 4 '{"name":"Bread","category":"bakery","price":2.4,"tags":["fresh"]}'
add 5 '{"name":"Pineapple","category":"fruit","price":2.4}'
add 6 '{"name":"Cheese","category":"dairy","price":7.99,"tags":["aged"]}'
check "blank name" 400 '' "${J[@]}" -X POST $U/products -d '{"name":"","category":"fruit","price":1}'
check "blank category" 400 '' "${J[@]}" -X POST $U/products -d '{"name":"x","category":" ","price":1}'
check "negative price" 400 '' "${J[@]}" -X POST $U/products -d '{"name":"x","category":"y","price":-0.01}'
check "get" 200 '"id":6 && "name":"Cheese" && "price":7.99' $U/products/6
check "get missing" 404 '' $U/products/99
check "patch price" 200 '"id":6 && "name":"Cheese" && "price":8.5 && "tags":\["aged"\]' "${J[@]}" -X PATCH $U/products/6 -d '{"price":8.5}'
check "patch name tags" 200 '"name":"Old Cheese" && "price":8.5 && "tags":\["aged","hard"\]' "${J[@]}" -X PATCH $U/products/6 -d '{"name":"Old Cheese","tags":["aged","hard"]}'
check "patch bad" 400 '' "${J[@]}" -X PATCH $U/products/6 -d '{"price":-1}'
check "patch blank" 400 '' "${J[@]}" -X PATCH $U/products/6 -d '{"name":""}'
check "patch kept" 200 '"name":"Old Cheese" && "price":8.5' $U/products/6
check "patch missing" 404 '' "${J[@]}" -X PATCH $U/products/99 -d '{"price":1}'
ids() { grep -oE '"id":[0-9]+' <<<"$LAST" | cut -d: -f2 | tr '\n' ' '; }
list() {
	local name=$1 want=$2 query=$3
	check "$name" 200 '"items":' "$U/products?$query"
	local got
	got=$(ids)
	[[ "$got" == "$want" ]] || { echo "FAIL $name: ids '$got', want '$want'"; fails=$((fails + 1)); }
}
list "all" "1 2 3 4 5 6 " ""
check "envelope" 200 '"total":6 && "page":1 && "per_page":10' "$U/products"
list "q" "1 3 5 " "q=APPLE"
list "category" "4 3 " "category=bakery&sort=price"
list "tag" "1 4 " "tag=fresh"
list "price range" "4 5 3 " "min_price=2.4&max_price=3&sort=price"
list "sort -price" "6 3 4 5 1 2 " "sort=-price"
list "sort name" "2 4 3 6 5 1 " "sort=name"
list "page 2" "3 4 " "per_page=2&page=2"
check "page meta" 200 '"total":6 && "page":2 && "per_page":2' "$U/products?per_page=2&page=2"
list "page past end" "" "per_page=4&page=3"
check "filter total" 200 '"total":3 && "per_page":1' "$U/products?q=apple&per_page=1"
check "bad sort" 400 '' "$U/products?sort=color"
check "bad page" 400 '' "$U/products?page=0"
check "bad per_page" 400 '' "$U/products?per_page=101"
check "bad per_page 0" 400 '' "$U/products?per_page=0"
check "categories" 200 '' $U/categories
jtest "categories content" "[(c['name'], c['count'], c['avg_price']) for c in j] == [('bakery', 2, 2.7), ('dairy', 1, 8.5), ('fruit', 3, 1.38)]"
finish
