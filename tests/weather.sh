# Погодный бэкенд examples/weather/weather.kh целиком: fetch, every, float,
# варианты, сохранение store. Вместо Open-Meteo — поддельный сервис на Khrip
# (tests/weather/meteo.kh), вместо Telegram — приёмник вебхуков (hook.kh).
# Подключается из tests/run.sh (использует его KHC, tmp, failed, pass).

W_METEO=${W_METEO:-18601}
W_HOOK=${W_HOOK:-18602}
W_APP=${W_APP:-18603}
W_TICK=${W_TICK:-18604}

w_ok() {
	pass=$((pass + 1))
}

# w_check <название> <ожидаемый код> <образец в теле или ""> <curl-аргументы...>
w_check() {
	local name=$1 want=$2 pattern=$3
	shift 3
	local out code body
	out=$(curl -s -w '\n%{http_code}' "$@")
	code=${out##*$'\n'}
	body=${out%$'\n'*}
	local ok=1 rest=$pattern p
	[[ "$code" == "$want" ]] || ok=0
	# несколько образцов через « && » — все должны найтись
	while [[ -n "$rest" ]]; do
		p=${rest%% && *}
		if [[ "$p" == "$rest" ]]; then rest=""; else rest=${rest#* && }; fi
		grep -qE -- "$p" <<<"$body" || ok=0
	done
	if [[ $ok -eq 1 ]]; then
		w_ok
	else
		failed "weather: $name" "код $code, тело: $body"
	fi
}

w_wait() {
	for _ in $(seq 200); do
		curl -s -o /dev/null "http://127.0.0.1:$1$2" && return 0
		sleep 0.02
	done
	return 1
}

w_build() {
	if ! "$KHC" -o "$tmp/$1" "$2" 2>"$tmp/$1.err"; then
		failed "weather" "$2 не скомпилировался: $(cat "$tmp/$1.err")"
		return 1
	fi
}

w_build meteo tests/weather/meteo.kh || return 0
w_build hook tests/weather/hook.kh || return 0
w_build app examples/weather/weather.kh || return 0
w_build tick tests/weather/tick.kh || return 0

PORT=$W_METEO "$tmp/meteo" 2>/dev/null &
w_meteo_pid=$!
PORT=$W_HOOK "$tmp/hook" 2>/dev/null &
w_hook_pid=$!
w_start_app() {
	PORT=$W_APP METEO_URL=http://127.0.0.1:$W_METEO GEO_URL=http://127.0.0.1:$W_METEO KHRIP_DATA=$tmp/alerts.json "$tmp/app" 2>"$tmp/app.log" &
	w_app_pid=$!
	w_wait $W_APP /alerts
}
w_wait $W_METEO "/v1/search?name=x"
w_wait $W_HOOK /received
w_start_app

A=http://127.0.0.1:$W_APP
M=http://127.0.0.1:$W_METEO
H=http://127.0.0.1:$W_HOOK

w_check "погода" 200 '"city":"Moscow" && "temperature":21.5' "$A/weather?city=Moscow"
w_check "погода: небо" 200 '"sky":"overcast"' "$A/weather?city=Moscow"
w_check "город с пробелом" 200 '"city":"New York"' "$A/weather?city=New%20York"
w_check "нет города" 502 'not available' "$A/weather?city=Nowhere"
w_check "нет параметра" 400 "missing query parameter 'city'" "$A/weather"
w_check "подписка" 201 '"id":1 && "fired":false' -X POST "$A/alerts" -d "{\"city\":\"Moscow\",\"webhook\":\"$H/hook\",\"chat_id\":\"42\",\"below\":0}"
w_check "подписка: плохой вебхук" 400 'webhook must be' -X POST "$A/alerts" -d '{"city":"Moscow","webhook":"ftp://x"}'
w_check "подписка: нет порога" 400 'set below or above' -X POST "$A/alerts" -d "{\"city\":\"Moscow\",\"webhook\":\"$H/hook\"}"
w_check "тепло — тихо" 200 '^0$' -X POST "$A/alerts/check"
w_check "похолодание" 204 '' -X POST "$M/set?t=-3.5"
w_check "уведомление" 200 '^1$' -X POST "$A/alerts/check"
w_check "доставлено" 200 '"chat_id":"42" && "temperature":-3.5 && Moscow: -3.5°C, below 0°C' "$H/received"
w_check "второй раз не шлём" 200 '^0$' -X POST "$A/alerts/check"
w_check "потепление" 204 '' -X POST "$M/set?t=5"
w_check "снова ок" 200 '^0$' -X POST "$A/alerts/check"
w_check "снова холод" 204 '' -X POST "$M/set?t=-1"
w_check "второе уведомление" 200 '^1$' -X POST "$A/alerts/check"

# сохранение: SIGTERM записывает store, после перезапуска подписка на месте
kill -TERM $w_app_pid
wait $w_app_pid 2>/dev/null
if grep -q '"fired":true' "$tmp/alerts.json" 2>/dev/null; then w_ok; else failed "weather: store на диске" "$(cat "$tmp/alerts.json" 2>&1)"; fi
w_start_app
w_check "после перезапуска" 200 '"id":1 && "fired":true && "last":-1' "$A/alerts"
w_check "новый id после перезапуска" 201 '"id":2' -X POST "$A/alerts" -d "{\"city\":\"Paris\",\"webhook\":\"$H/hook\",\"above\":30}"
w_check "удаление" 204 '' -X DELETE "$A/alerts/1"

# every: задача сама увеличивает счётчик
PORT=$W_TICK "$tmp/tick" 2>/dev/null &
w_tick_pid=$!
w_wait $W_TICK /ticks
sleep 0.6
ticks=$(curl -s "http://127.0.0.1:$W_TICK/ticks")
if [[ "$ticks" =~ ^[0-9]+$ ]] && ((ticks >= 3)); then w_ok; else failed "weather: every" "ticks = $ticks"; fi

kill $w_meteo_pid $w_hook_pid $w_app_pid $w_tick_pid 2>/dev/null
wait 2>/dev/null
