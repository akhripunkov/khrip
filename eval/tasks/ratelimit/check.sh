#!/usr/bin/env bash
# Проверка ограничения частоты; сервер запущен с WINDOW_SECONDS=2.
. "$(dirname "$0")/../../lib.sh"

K=(-H 'X-API-Key: alpha')
check "no key" 401 '' $U/api/ping
check "limits idle" 200 '"key":"alpha" && "used":0 && "remaining":5 && "reset_in":0' $U/limits/alpha
check "ping 1" 200 '"pong":true && "remaining":4' "${K[@]}" $U/api/ping
check "ping 2" 200 '"remaining":3' "${K[@]}" $U/api/ping
check "time" 200 '"time":'"$ISO" "${K[@]}" $U/api/time
check "limits" 200 '"key":"alpha" && "used":3 && "remaining":2 && "reset_in":[12]' $U/limits/alpha
check "ping 4" 200 '"remaining":1' "${K[@]}" $U/api/ping
check "ping 5" 200 '"remaining":0' "${K[@]}" $U/api/ping
check "ping 6" 429 'H:^retry-after: [12]$' "${K[@]}" $U/api/ping
check "time 7" 429 'H:^retry-after: [12]$' "${K[@]}" $U/api/time
check "limits full" 200 '"used":5 && "remaining":0' $U/limits/alpha
check "other key" 200 '"remaining":4' -H 'X-API-Key: beta' $U/api/ping
check "limits other" 200 '"key":"beta" && "used":1' $U/limits/beta
sleep 2.2
check "new window" 200 '"remaining":4' "${K[@]}" $U/api/ping
check "limits new window" 200 '"used":1 && "remaining":4' $U/limits/alpha
# Одновременно 20 запросов нового ключа — ровно 5 проходят.
codes=$(seq 20 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: gamma' $U/api/ping | sort | uniq -c | tr -s ' ' | tr '\n' ';')
[[ "$codes" == " 5 200; 15 429;" ]] || { echo "FAIL concurrent requests: $codes"; fails=$((fails + 1)); }
total=$((total + 1))
finish
