#!/usr/bin/env bash
# Проверка магазина в PostgreSQL; две копии сервера: $U и $U2.
# Номера берутся из ответов: неудачная вставка может занять номер в последовательности.
. "$(dirname "$0")/../../lib.sh"
U2=${U2:-$U}

check "category" 201 '"name":"Fruit"' "${J[@]}" -X POST $U/categories -d '{"name":" Fruit "}'
cf=$(jval "j['id']")
check "category 2" 201 '"name":"Bakery"' "${J[@]}" -X POST $U2/categories -d '{"name":"Bakery"}'
cb=$(jval "j['id']")
check "category 3" 201 '"name":"Toys"' "${J[@]}" -X POST $U/categories -d '{"name":"Toys"}'
ct=$(jval "j['id']")
check "category dup" 409 '' "${J[@]}" -X POST $U2/categories -d '{"name":"fruit"}'
check "category blank" 400 '' "${J[@]}" -X POST $U/categories -d '{"name":"   "}'
check "category long" 400 '' "${J[@]}" -X POST $U/categories -d "{\"name\":\"$(printf 'a%.0s' $(seq 51))\"}"
check "categories" 200 '' $U/categories
jtest "categories sorted" "[(c['id'], c['name']) for c in j] == [($cb, 'Bakery'), ($cf, 'Fruit'), ($ct, 'Toys')]"

product() {
	check "product $1" 201 "\"name\":\"$1\"" "${J[@]}" -X POST "$2/products" -d "$3"
	jval "j['id']" >"$out/id"
}
out=$(mktemp -d)
product "Green Apple" $U "{\"name\":\"Green Apple\",\"category_id\":$cf,\"price\":120,\"stock\":10,\"tags\":[\"green\",\"fresh\",\"green\"]}"
p1=$(cat "$out/id")
jtest "product fields" "j['category_id'] == $cf and j['price'] == 120 and j['stock'] == 10 and j['tags'] == ['green', 'fresh']"
product "Red Apple" $U2 "{\"name\":\"Red Apple\",\"category_id\":$cf,\"price\":90,\"stock\":5,\"tags\":[\"red\",\"fresh\"]}"
p2=$(cat "$out/id")
product "Bread" $U "{\"name\":\"Bread\",\"category_id\":$cb,\"price\":250,\"stock\":3}"
p3=$(cat "$out/id")
jtest "no tags" "j['tags'] == []"
product "Apple Pie" $U "{\"name\":\"Apple Pie\",\"category_id\":$cb,\"price\":900,\"stock\":0,\"tags\":[\"sweet\"]}"
p4=$(cat "$out/id")
product "Banana" $U "{\"name\":\"Banana\",\"category_id\":$cf,\"price\":90,\"stock\":40}"
p5=$(cat "$out/id")
check "unknown category" 404 '' "${J[@]}" -X POST $U/products -d '{"name":"X","category_id":999999,"price":1,"stock":1}'
check "zero price" 400 '' "${J[@]}" -X POST $U/products -d "{\"name\":\"X\",\"category_id\":$cf,\"price\":0,\"stock\":1}"
check "negative stock" 400 '' "${J[@]}" -X POST $U/products -d "{\"name\":\"X\",\"category_id\":$cf,\"price\":1,\"stock\":-1}"
check "blank name" 400 '' "${J[@]}" -X POST $U/products -d "{\"name\":\" \",\"category_id\":$cf,\"price\":1,\"stock\":1}"
check "bad tag" 400 '' "${J[@]}" -X POST $U/products -d "{\"name\":\"X\",\"category_id\":$cf,\"price\":1,\"stock\":1,\"tags\":[\"Big\"]}"
check "too many tags" 400 '' "${J[@]}" -X POST $U/products -d "{\"name\":\"X\",\"category_id\":$cf,\"price\":1,\"stock\":1,\"tags\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\"]}"
check "get" 200 "\"id\":$p2 && \"name\":\"Red Apple\"" $U2/products/$p2
check "get missing" 404 '' $U/products/999999
check "patch" 200 "\"id\":$p2 && \"price\":95 && \"name\":\"Red Apple\" && \"stock\":5" "${J[@]}" -X PATCH $U/products/$p2 -d '{"price":95}'
check "patch tags" 200 '' "${J[@]}" -X PATCH $U2/products/$p2 -d '{"tags":["red","juicy"]}'
jtest "patched tags" "j['tags'] == ['red', 'juicy'] and j['price'] == 95"
check "patch bad" 400 '' "${J[@]}" -X PATCH $U/products/$p2 -d '{"price":-5}'
check "patch missing" 404 '' "${J[@]}" -X PATCH $U/products/999999 -d '{"price":5}'

# Поиск, фильтры, сортировка, страницы.
check "list" 200 '' $U/products
jtest "list all" "[p['id'] for p in j['items']] == [$p1, $p2, $p3, $p4, $p5] and j['total'] == 5"
check "by category" 200 '' "$U/products?category_id=$cf&sort=-price"
jtest "category sorted" "[p['id'] for p in j['items']] == [$p1, $p2, $p5] and j['total'] == 3"
check "by tag" 200 '' "$U2/products?tag=fresh"
jtest "tag" "[p['id'] for p in j['items']] == [$p1]"
check "q" 200 '' "$U/products?q=APPLE&sort=price"
jtest "q sorted" "[p['id'] for p in j['items']] == [$p2, $p1, $p4]"
check "price range" 200 '' "$U/products?min_price=90&max_price=120&sort=name"
jtest "range" "[p['name'] for p in j['items']] == ['Banana', 'Green Apple', 'Red Apple']"
check "in stock" 200 '' "$U/products?in_stock=true&q=apple"
jtest "in stock only" "[p['id'] for p in j['items']] == [$p1, $p2]"
check "page" 200 '' "$U/products?per_page=2&page=2&sort=price"
jtest "page 2" "[p['id'] for p in j['items']] == [$p1, $p3] and j['total'] == 5"
check "page past end" 200 '' "$U/products?per_page=2&page=9"
jtest "empty page" "j['items'] == [] and j['total'] == 5"
check "bad sort" 400 '' "$U/products?sort=stock"
check "bad per_page" 400 '' "$U/products?per_page=51"
check "bad page" 400 '' "$U/products?page=0"
check "bad min" 400 '' "$U/products?min_price=x"

# Заказы.
check "order" 201 "\"customer\":\"ann@example.com\" && \"status\":\"placed\" && \"created_at\":$ISO" \
	"${J[@]}" -X POST $U/orders -d "{\"customer\":\"Ann@Example.com\",\"lines\":[{\"product_id\":$p1,\"qty\":2},{\"product_id\":$p3,\"qty\":1},{\"product_id\":$p1,\"qty\":1}]}"
o1=$(jval "j['id']")
jtest "order lines" "j['lines'] == [{'product_id': $p1, 'qty': 3, 'price': 120}, {'product_id': $p3, 'qty': 1, 'price': 250}] and j['total'] == 610"
check "stock taken" 200 '"stock":7' $U2/products/$p1
check "not enough" 409 '' "${J[@]}" -X POST $U2/orders -d "{\"customer\":\"bob@x.io\",\"lines\":[{\"product_id\":$p2,\"qty\":1},{\"product_id\":$p3,\"qty\":3}]}"
check "nothing taken" 200 '"stock":5' $U/products/$p2
check "bad customer" 400 '' "${J[@]}" -X POST $U/orders -d "{\"customer\":\"bob at x\",\"lines\":[{\"product_id\":$p2,\"qty\":1}]}"
check "no lines" 400 '' "${J[@]}" -X POST $U/orders -d '{"customer":"bob@x.io","lines":[]}'
check "zero qty" 400 '' "${J[@]}" -X POST $U/orders -d "{\"customer\":\"bob@x.io\",\"lines\":[{\"product_id\":$p2,\"qty\":0}]}"
check "unknown product" 404 '' "${J[@]}" -X POST $U/orders -d '{"customer":"bob@x.io","lines":[{"product_id":999999,"qty":1}]}'
check "order 2" 201 '"total":190' "${J[@]}" -X POST $U2/orders -d "{\"customer\":\"bob@x.io\",\"lines\":[{\"product_id\":$p2,\"qty\":2}]}"
o2=$(jval "j['id']")
check "order 3" 201 '"total":95' "${J[@]}" -X POST $U/orders -d "{\"customer\":\"ANN@example.com\",\"lines\":[{\"product_id\":$p2,\"qty\":1}]}"
o3=$(jval "j['id']")
check "cancel" 200 "\"id\":$o2 && \"status\":\"cancelled\"" -X POST $U/orders/$o2/cancel
check "cancel again" 409 '' -X POST $U2/orders/$o2/cancel
check "cancel missing" 404 '' -X POST $U/orders/999999/cancel
check "stock back" 200 '"stock":4' $U/products/$p2
check "customer orders" 200 '' $U2/customers/ann@EXAMPLE.com/orders
jtest "newest first" "[o['id'] for o in j] == [$o3, $o1] and j[1]['lines'][0]['qty'] == 3"
check "stats" 200 '' $U/stats/categories
jtest "stats values" "j == [{'category': 'Fruit', 'products': 3, 'units_sold': 4, 'revenue': 455}, {'category': 'Bakery', 'products': 2, 'units_sold': 1, 'revenue': 250}, {'category': 'Toys', 'products': 0, 'units_sold': 0, 'revenue': 0}]"

# Одновременно, на двух копиях: 50 заказов по 1 при запасе 20 — ровно 20.
product "Robot" $U "{\"name\":\"Robot\",\"category_id\":$ct,\"price\":1000,\"stock\":20}"
p6=$(cat "$out/id")
same "concurrent orders" "$(race 50 25 /orders "${J[@]}" -X POST -d "{\"customer\":\"r@x.io\",\"lines\":[{\"product_id\":$p6,\"qty\":1},{\"product_id\":$p5,\"qty\":1}]}")" " 20 201; 30 409;"
check "race stock" 200 '"stock":0' $U/products/$p6
check "race other line" 200 '"stock":20' $U2/products/$p5
rm -rf "$out"
echo "$p2" >"${STATE:-/dev/null}"
finish
