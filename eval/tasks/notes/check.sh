#!/usr/bin/env bash
# Проверка заметок с учётными записями; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "register" 201 '"id":1 && "username":"ann"' "${J[@]}" -X POST $U/register -d '{"username":"ann","password":"secret-ann"}'
check "register 2" 201 '"id":2 && "username":"bob"' "${J[@]}" -X POST $U/register -d '{"username":"bob","password":"secret-bob"}'
check "taken" 409 '' "${J[@]}" -X POST $U/register -d '{"username":"ann","password":"another-one"}'
check "short name" 400 '' "${J[@]}" -X POST $U/register -d '{"username":"an","password":"secret-ann"}'
check "short password" 400 '' "${J[@]}" -X POST $U/register -d '{"username":"carl","password":"1234567"}'
check "no password" 400 '' "${J[@]}" -X POST $U/register -d '{"username":"carl"}'
check "password not echoed" 201 '"username":"dora"' "${J[@]}" -X POST $U/register -d '{"username":"dora","password":"pa55word!"}'
grep -q 'pa55word' <<<"$LAST" && { echo "FAIL password in response"; fails=$((fails + 1)); }
check "login" 200 '"token":"[^"]{20,}"' "${J[@]}" -X POST $U/login -d '{"username":"ann","password":"secret-ann"}'
ta=$(field token)
check "login again" 200 '"token":"[^"]{20,}"' "${J[@]}" -X POST $U/login -d '{"username":"ann","password":"secret-ann"}'
ta2=$(field token)
[[ "$ta" != "$ta2" ]] || { echo "FAIL login gives the same token"; fails=$((fails + 1)); }
total=$((total + 1))
check "login bob" 200 '"token"' "${J[@]}" -X POST $U/login -d '{"username":"bob","password":"secret-bob"}'
tb=$(field token)
check "wrong password" 401 '' "${J[@]}" -X POST $U/login -d '{"username":"ann","password":"secret-bob"}'
check "wrong user" 401 '' "${J[@]}" -X POST $U/login -d '{"username":"nobody","password":"secret-ann"}'
A=(-H "Authorization: Bearer $ta")
A2=(-H "Authorization: Bearer $ta2")
B=(-H "Authorization: Bearer $tb")
check "no token" 401 '' $U/notes
check "bad token" 401 '' -H 'Authorization: Bearer nope-nope-nope-nope-nope' $U/notes
check "not bearer" 401 '' -H "Authorization: $ta" $U/notes
check "create no token" 401 '' "${J[@]}" -X POST $U/notes -d '{"title":"x","text":"y"}'
check "create" 201 '"id":1 && "title":"Shop" && "text":"milk, eggs" && "created_at":'"$ISO" "${J[@]}" "${A[@]}" -X POST $U/notes -d '{"title":"Shop","text":"milk, eggs"}'
check "create bob" 201 '"id":2 && "title":"Bob'"'"'s"' "${J[@]}" "${B[@]}" -X POST $U/notes -d "{\"title\":\"Bob's\",\"text\":\"\"}"
check "create 3" 201 '"id":3 && "title":"Ideas"' "${J[@]}" "${A2[@]}" -X POST $U/notes -d '{"title":"Ideas","text":"line 1\nline 2"}'
check "blank title" 400 '' "${J[@]}" "${A[@]}" -X POST $U/notes -d '{"title":" ","text":"y"}'
check "list ann" 200 '^\[\{[^{}]*"id":1[^{}]*\},\{[^{}]*"id":3[^{}]*"text":"line 1\\nline 2"[^{}]*\}\]$' "${A[@]}" $U/notes
check "list bob" 200 '^\[\{[^{}]*"id":2[^{}]*\}\]$' "${B[@]}" $U/notes
check "get own" 200 '"id":1 && "title":"Shop"' "${A[@]}" $U/notes/1
check "get other's" 404 '' "${B[@]}" $U/notes/1
check "get missing" 404 '' "${A[@]}" $U/notes/99
check "get no token" 401 '' $U/notes/1
check "delete other's" 404 '' "${B[@]}" -X DELETE $U/notes/1
check "delete" 204 '' "${A[@]}" -X DELETE $U/notes/1
check "delete again" 404 '' "${A[@]}" -X DELETE $U/notes/1
check "list after delete" 200 '^\[\{[^{}]*"id":3[^{}]*\}\]$' "${A[@]}" $U/notes
finish
