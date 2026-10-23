#!/usr/bin/env bash
# Проверка трекера задач в PostgreSQL; две копии сервера: $U и $U2.
# Номера пользователей берутся из ответов.
. "$(dirname "$0")/../../lib.sh"
U2=${U2:-$U}

check "user" 201 '"email":"ann@example.com" && "name":"Ann"' "${J[@]}" -X POST $U/users -d '{"email":"Ann@Example.com","name":"Ann"}'
ann=$(jval "j['id']")
check "user 2" 201 '"email":"bob@x.io"' "${J[@]}" -X POST $U2/users -d '{"email":"bob@x.io","name":"Bob"}'
bob=$(jval "j['id']")
check "user 3" 201 '"name":"Cid"' "${J[@]}" -X POST $U/users -d '{"email":"cid@x.io","name":"Cid"}'
cid=$(jval "j['id']")
check "user dup" 409 '' "${J[@]}" -X POST $U2/users -d '{"email":"ANN@example.COM","name":"Other"}'
check "user bad email" 400 '' "${J[@]}" -X POST $U/users -d '{"email":"ann@","name":"X"}'
check "user two at" 400 '' "${J[@]}" -X POST $U/users -d '{"email":"a@b@c","name":"X"}'
check "user space" 400 '' "${J[@]}" -X POST $U/users -d '{"email":"a b@c","name":"X"}'
check "user blank" 400 '' "${J[@]}" -X POST $U/users -d '{"email":"z@x.io","name":" "}'
check "project" 201 "\"key\":\"API\" && \"name\":\"Public API\" && \"owner_id\":$ann" "${J[@]}" -X POST $U/projects -d "{\"key\":\"API\",\"name\":\"Public API\",\"owner_id\":$ann}"
check "project 2" 201 '"key":"WEB"' "${J[@]}" -X POST $U2/projects -d "{\"key\":\"WEB\",\"name\":\"Site\",\"owner_id\":$bob}"
check "project dup" 409 '' "${J[@]}" -X POST $U/projects -d "{\"key\":\"API\",\"name\":\"Again\",\"owner_id\":$bob}"
check "project lower" 400 '' "${J[@]}" -X POST $U/projects -d "{\"key\":\"api2\",\"name\":\"X\",\"owner_id\":$bob}"
check "project long" 400 '' "${J[@]}" -X POST $U/projects -d "{\"key\":\"ABCDEF\",\"name\":\"X\",\"owner_id\":$bob}"
check "project short" 400 '' "${J[@]}" -X POST $U/projects -d "{\"key\":\"A\",\"name\":\"X\",\"owner_id\":$bob}"
check "project owner" 404 '' "${J[@]}" -X POST $U/projects -d '{"key":"OPS","name":"Ops","owner_id":999999}'

check "issue" 201 '"key":"API-1" && "project":"API" && "number":1 && "status":"open" && "priority":"medium" && "assignee_id":null && "created_at":'"$ISO"' && "updated_at":'"$ISO" \
	"${J[@]}" -X POST $U/projects/API/issues -d '{"title":"Login fails"}'
check "issue 2" 201 "\"key\":\"API-2\" && \"priority\":\"high\" && \"assignee_id\":$bob" "${J[@]}" -X POST $U2/projects/API/issues -d "{\"title\":\"Rate limits\",\"priority\":\"high\",\"assignee_id\":$bob}"
check "issue 3" 201 '"key":"API-3"' "${J[@]}" -X POST $U/projects/API/issues -d "{\"title\":\"Docs for login\",\"priority\":\"low\",\"assignee_id\":$cid}"
check "issue other project" 201 '"key":"WEB-1" && "number":1' "${J[@]}" -X POST $U/projects/WEB/issues -d "{\"title\":\"Footer\",\"assignee_id\":null}"
check "issue bad priority" 400 '' "${J[@]}" -X POST $U/projects/API/issues -d '{"title":"X","priority":"urgent"}'
check "issue blank" 400 '' "${J[@]}" -X POST $U/projects/API/issues -d '{"title":"  "}'
check "issue long" 400 '' "${J[@]}" -X POST $U/projects/API/issues -d "{\"title\":\"$(printf 'a%.0s' $(seq 201))\"}"
check "issue long cyrillic" 400 '' "${J[@]}" -X POST $U/projects/API/issues -d "{\"title\":\"$(printf 'ж%.0s' $(seq 201))\"}"
check "issue assignee" 404 '' "${J[@]}" -X POST $U/projects/API/issues -d '{"title":"X","assignee_id":999999}'
check "issue project" 404 '' "${J[@]}" -X POST $U/projects/NOPE/issues -d '{"title":"X"}'
check "issue 4 after errors" 201 '"key":"API-4" && "number":4' "${J[@]}" -X POST $U2/projects/API/issues -d "{\"title\":\"Slow search\",\"assignee_id\":$bob}"
check "get" 200 "\"key\":\"API-2\" && \"title\":\"Rate limits\" && \"assignee_id\":$bob" $U/issues/API-2
check "get missing" 404 '' $U/issues/API-99
check "get bad key" 404 '' $U/issues/nonsense

# PATCH: только указанные поля; null снимает исполнителя.
created=$(curl -s $U/issues/API-2 | python3 -c 'import sys, json; print(json.load(sys.stdin)["updated_at"])')
sleep 1.1
check "patch status" 200 "\"key\":\"API-2\" && \"status\":\"in_progress\" && \"priority\":\"high\" && \"assignee_id\":$bob" "${J[@]}" -X PATCH $U2/issues/API-2 -d '{"status":"in_progress"}'
jtest "updated_at moved" "j['updated_at'] != '$created' and j['created_at'] == '$created'"
check "patch unassign" 200 '"assignee_id":null && "status":"in_progress"' "${J[@]}" -X PATCH $U/issues/API-2 -d '{"assignee_id":null}'
check "patch assign" 200 "\"assignee_id\":$ann && \"title\":\"Rate limits v2\"" "${J[@]}" -X PATCH $U/issues/API-2 -d "{\"assignee_id\":$ann,\"title\":\"Rate limits v2\"}"
check "patch done" 200 '"status":"done"' "${J[@]}" -X PATCH $U/issues/API-3 -d '{"status":"done"}'
check "patch bad status" 400 '' "${J[@]}" -X PATCH $U/issues/API-1 -d '{"status":"closed"}'
check "patch blank title" 400 '' "${J[@]}" -X PATCH $U/issues/API-1 -d '{"title":""}'
check "patch bad assignee" 404 '' "${J[@]}" -X PATCH $U/issues/API-1 -d '{"assignee_id":999999}'
check "patch missing" 404 '' "${J[@]}" -X PATCH $U/issues/API-99 -d '{"status":"done"}'
check "unchanged" 200 '"status":"open" && "title":"Login fails" && "assignee_id":null' $U2/issues/API-1

# Списки и фильтры.
check "list" 200 '' $U/projects/API/issues
jtest "list order" "[i['number'] for i in j] == [1, 2, 3, 4]"
check "by status" 200 '' "$U/projects/API/issues?status=open"
jtest "status open" "[i['key'] for i in j] == ['API-1', 'API-4']"
check "by assignee" 200 '' "$U2/projects/API/issues?assignee_id=$bob"
jtest "assignee" "[i['key'] for i in j] == ['API-4']"
check "unassigned" 200 '' "$U/projects/API/issues?assignee_id=none"
jtest "none" "[i['key'] for i in j] == ['API-1']"
check "search" 200 '' "$U/projects/API/issues?q=LOGIN"
jtest "q" "[i['key'] for i in j] == ['API-1', 'API-3']"
check "search and status" 200 '' "$U/projects/API/issues?q=login&status=done"
jtest "q status" "[i['key'] for i in j] == ['API-3']"
check "bad status filter" 400 '' "$U/projects/API/issues?status=closed"
check "bad assignee filter" 400 '' "$U/projects/API/issues?assignee_id=bob"
check "list missing" 404 '' $U/projects/NOPE/issues
check "summary" 200 '' $U/projects/API/summary
jtest "summary values" "j == {'total': 4, 'open': 2, 'in_progress': 1, 'done': 1, 'assignees': sorted([{'id': $ann, 'name': 'Ann', 'active': 1}, {'id': $bob, 'name': 'Bob', 'active': 1}], key=lambda a: a['id'])}"
check "summary missing" 404 '' $U/projects/NOPE/summary

# Удаление: номер не выдаётся снова.
check "delete" 204 '' -X DELETE $U/issues/API-4
check "delete again" 404 '' -X DELETE $U2/issues/API-4
check "deleted" 404 '' $U/issues/API-4
check "after delete" 201 '"key":"API-5" && "number":5' "${J[@]}" -X POST $U/projects/API/issues -d '{"title":"Next"}'

# Одновременно, на двух копиях: 40 задач — номера 6…45 без повторов и пропусков.
same "concurrent issues" "$(race 40 20 /projects/WEB/issues "${J[@]}" -X POST -d '{"title":"Race"}')" " 40 201;"
check "numbers" 200 '' "$U/projects/WEB/issues?q=race"
jtest "no gaps" "[i['number'] for i in j] == list(range(2, 42))"
check "summary race" 200 '"total":41 && "open":41' $U2/projects/WEB/summary
echo "$ann $bob" >"${STATE:-/dev/null}"
finish
