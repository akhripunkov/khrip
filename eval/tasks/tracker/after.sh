#!/usr/bin/env bash
# После перезапуска: данные в базе. $STATE — номера из check.sh.
. "$(dirname "$0")/../../lib.sh"
read -r ann bob <"$STATE"
check "kept issue" 200 "\"key\":\"API-2\" && \"title\":\"Rate limits v2\" && \"assignee_id\":$ann && \"status\":\"in_progress\"" $U/issues/API-2
check "kept numbering" 201 '"key":"API-6"' "${J[@]}" -X POST $U/projects/API/issues -d '{"title":"After restart"}'
# длина — в символах: 200 букв кириллицы — 400 байт
cyr=$(printf 'ж%.0s' $(seq 200))
check "cyrillic title of 200" 201 "\"key\":\"API-7\" && \"title\":\"$cyr\"" "${J[@]}" -X POST $U/projects/API/issues -d "{\"title\":\"$cyr\"}"
check "kept user" 409 '' "${J[@]}" -X POST $U/users -d '{"email":"bob@X.io","name":"Bob"}'
check "kept summary" 200 '"total":41' $U/projects/WEB/summary
finish
