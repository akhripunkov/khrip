#!/usr/bin/env bash
# Проверка сокращателя ссылок; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "create random" 201 '"code":"[A-Za-z0-9]{7}" && "url":"https://example.com/a\?x=1" && "clicks":0' \
	"${J[@]}" -X POST $U/links -d '{"url":"https://example.com/a?x=1"}'
r1=$(field code)
check "create custom" 201 '"code":"my-docs_1" && "clicks":0' "${J[@]}" -X POST $U/links -d '{"url":"http://docs.example.org","code":"my-docs_1"}'
check "duplicate code" 409 '' "${J[@]}" -X POST $U/links -d '{"url":"http://other.example.org","code":"my-docs_1"}'
check "bad url" 400 '' "${J[@]}" -X POST $U/links -d '{"url":"ftp://example.com"}'
check "bad url 2" 400 '' "${J[@]}" -X POST $U/links -d '{"url":"example.com"}'
check "short code" 400 '' "${J[@]}" -X POST $U/links -d '{"url":"https://example.com","code":"ab"}'
check "long code" 400 '' "${J[@]}" -X POST $U/links -d "{\"url\":\"https://example.com\",\"code\":\"$(printf 'a%.0s' {1..33})\"}"
check "bad code chars" 400 '' "${J[@]}" -X POST $U/links -d '{"url":"https://example.com","code":"no spaces"}'
check "bad code slash" 400 '' "${J[@]}" -X POST $U/links -d '{"url":"https://example.com","code":"a/b/c"}'
check "missing url" 400 '' "${J[@]}" -X POST $U/links -d '{"code":"abcd"}'
check "redirect" 302 'H:^location: http://docs\.example\.org/?$' $U/my-docs_1
check "redirect 2" 302 'H:^location: http://docs\.example\.org/?$' $U/my-docs_1
check "redirect random" 302 'H:^location: https://example\.com/a\?x=1$' "$U/$r1"
check "redirect unknown" 404 '' $U/nothing-here
check "get" 200 '"code":"my-docs_1" && "clicks":2 && "url":"http://docs.example.org"' $U/links/my-docs_1
check "get random" 200 "\"code\":\"$r1\" && \"clicks\":1" "$U/links/$r1"
check "get unknown" 404 '' $U/links/zzz
check "create aaa" 201 '"code":"aaa"' "${J[@]}" -X POST $U/links -d '{"url":"https://a.example","code":"aaa"}'
check "create ccc" 201 '"code":"ccc"' "${J[@]}" -X POST $U/links -d '{"url":"https://c.example","code":"ccc"}'
check "create bbb" 201 '"code":"bbb"' "${J[@]}" -X POST $U/links -d '{"url":"https://b.example","code":"bbb"}'
for c in ccc bbb "$r1" "$r1"; do curl -s -o /dev/null "$U/$c"; done
check "list" 200 '' $U/links
jtest "list order" "[(l['code'], l['clicks']) for l in j] == [('$r1', 3), ('my-docs_1', 2), ('bbb', 1), ('ccc', 1), ('aaa', 0)]"
check "delete" 204 '' -X DELETE $U/links/aaa
check "delete again" 404 '' -X DELETE $U/links/aaa
check "deleted redirect" 404 '' $U/aaa
check "unique codes" 201 '' "${J[@]}" -X POST $U/links -d '{"url":"https://c.example"}'
c1=$(field code)
check "unique codes 2" 201 '' "${J[@]}" -X POST $U/links -d '{"url":"https://c.example"}'
c2=$(field code)
[[ "$c1" != "$c2" ]] || { echo "FAIL random codes repeat: $c1"; fails=$((fails + 1)); }
finish
