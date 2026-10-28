#!/usr/bin/env bash
# Проверка списка дел: необязательные поля, PATCH только присланных полей,
# поле type; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "create minimal" 201 '"id":1 && "title":"Buy milk" && "type":"task" && "notes":null && "due":null && "priority":null && "done":false' \
	"${J[@]}" -X POST $U/todos -d '{"title":"Buy milk"}'
check "create full" 201 '"id":2 && "title":"Plan trip" && "type":"note" && "notes":"Rome or Lisbon" && "due":"2026-11-03" && "priority":2 && "done":false' \
	"${J[@]}" -X POST $U/todos -d '{"title":"Plan trip","type":"note","notes":"Rome or Lisbon","due":"2026-11-03","priority":2}'
check "create nulls" 201 '"id":3 && "notes":null && "due":null && "priority":null' \
	"${J[@]}" -X POST $U/todos -d '{"title":"Call Ann","notes":null,"due":null,"priority":null}'
check "create p1" 201 '"id":4 && "priority":1' "${J[@]}" -X POST $U/todos -d '{"title":"Pay rent","priority":1,"due":"2026-11-01"}'
check "blank title" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"  "}'
check "no title" 400 '' "${J[@]}" -X POST $U/todos -d '{"type":"task"}'
check "bad type" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"x","type":"bug"}'
check "bad due" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"x","due":"2026-02-30"}'
check "bad due format" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"x","due":"03.11.2026"}'
check "bad priority" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"x","priority":6}'
check "bad priority 0" 400 '' "${J[@]}" -X POST $U/todos -d '{"title":"x","priority":0}'
check "get" 200 '"id":2 && "title":"Plan trip" && "notes":"Rome or Lisbon"' $U/todos/2
check "get missing" 404 '' $U/todos/99
# PATCH меняет только присланные поля
check "patch done" 200 '"id":2 && "title":"Plan trip" && "type":"note" && "notes":"Rome or Lisbon" && "due":"2026-11-03" && "priority":2 && "done":true' \
	"${J[@]}" -X PATCH $U/todos/2 -d '{"done":true}'
check "patch title" 200 '"title":"Plan the trip" && "notes":"Rome or Lisbon" && "due":"2026-11-03" && "priority":2 && "done":true' \
	"${J[@]}" -X PATCH $U/todos/2 -d '{"title":"Plan the trip"}'
check "patch optional" 200 '"id":1 && "title":"Buy milk" && "notes":"2 liters" && "priority":3 && "due":null && "done":false' \
	"${J[@]}" -X PATCH $U/todos/1 -d '{"notes":"2 liters","priority":3}'
check "patch type" 200 '"id":1 && "type":"note" && "notes":"2 liters" && "priority":3' "${J[@]}" -X PATCH $U/todos/1 -d '{"type":"note"}'
check "patch kept" 200 '"title":"Plan the trip" && "type":"note" && "notes":"Rome or Lisbon" && "due":"2026-11-03" && "priority":2 && "done":true' $U/todos/2
check "patch bad priority" 400 '' "${J[@]}" -X PATCH $U/todos/2 -d '{"priority":9}'
check "patch bad due" 400 '' "${J[@]}" -X PATCH $U/todos/2 -d '{"due":"2026-13-01"}'
check "patch blank title" 400 '' "${J[@]}" -X PATCH $U/todos/2 -d '{"title":""}'
check "patch bad type" 400 '' "${J[@]}" -X PATCH $U/todos/2 -d '{"type":"bug"}'
check "patch unchanged after 400" 200 '"title":"Plan the trip" && "priority":2 && "due":"2026-11-03"' $U/todos/2
check "patch missing" 404 '' "${J[@]}" -X PATCH $U/todos/99 -d '{"done":true}'
ids() { grep -oE '"id":[0-9]+' <<<"$LAST" | cut -d: -f2 | tr '\n' ' '; }
list() {
	local name=$1 want=$2 query=$3
	check "$name" 200 '' "$U/todos?$query"
	local got
	got=$(ids)
	[[ "$got" == "$want" ]] || { echo "FAIL $name: ids '$got', want '$want'"; fails=$((fails + 1)); }
}
list "all" "1 2 3 4 " ""
list "done" "2 " "done=true"
list "not done" "1 3 4 " "done=false"
list "type note" "1 2 " "type=note"
list "type task" "3 4 " "type=task"
list "sort priority" "4 2 1 3 " "sort=priority"
list "sort id" "1 2 3 4 " "sort=id"
list "filter and sort" "4 3 " "done=false&type=task&sort=priority"
check "bad sort" 400 '' "$U/todos?sort=title"
check "delete" 204 '' -X DELETE $U/todos/3
check "delete again" 404 '' -X DELETE $U/todos/3
check "get deleted" 404 '' $U/todos/3
list "after delete" "1 2 4 " ""
check "id after delete" 201 '"id":5' "${J[@]}" -X POST $U/todos -d '{"title":"Water plants"}'
finish
