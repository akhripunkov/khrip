#!/usr/bin/env bash
# Один сценарий запросов для всех версий TODO API: ./check.sh khrip|go|csharp|python
# Проверяет коды ответов и содержимое; печатает число проваленных проверок.
set -uo pipefail
cd "$(dirname "$0")"
lang=$1
port=8080
root=$(cd ../../../.. && pwd)
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT

case $lang in
khrip)
	"$root/build/khc" -o "$tmp/server" "${KHRIP_SRC:-khrip/main.kh}" || exit 1
	PORT=$port "$tmp/server" 2>/dev/null &
	;;
go)
	(cd go && go build -o "$tmp/server" .) || exit 1
	"$tmp/server" &
	;;
csharp)
	dotnet build csharp -c Release -o "$tmp/cs" --nologo -v q >/dev/null || exit 1
	dotnet "$tmp/cs/Todo.dll" >/dev/null 2>&1 &
	;;
python)
	(cd python && exec python3 -m uvicorn main:app --port $port --log-level error) &
	;;
esac
pid=$!
for _ in $(seq 300); do
	curl -s -o /dev/null "http://127.0.0.1:$port/stats" && break
	sleep 0.05
done

U=http://127.0.0.1:$port
fails=0
# check <название> <ожидаемый код> <образец в теле или ""> <curl-аргументы...>
check() {
	local name=$1 want=$2 pattern=$3
	shift 3
	local out code body
	out=$(curl -s -w '\n%{http_code}' "$@")
	code=${out##*$'\n'}
	body=${out%$'\n'*}
	local ok=1
	[[ "$code" == $want ]] || ok=0
	# несколько образцов через « && » — все должны найтись (порядок полей у языков разный)
	local rest=$pattern p
	while [[ -n "$rest" ]]; do
		p=${rest%% && *}
		if [[ "$p" == "$rest" ]]; then rest=""; else rest=${rest#* && }; fi
		grep -qE -- "$p" <<<"$body" || ok=0
	done
	if [[ $ok -eq 0 ]]; then
		echo "FAIL $name: $code $body"
		fails=$((fails + 1))
	fi
}
J=(-H 'Content-Type: application/json')
check "create" 201 '"id":1 && "status":"Todo" && "tags":\["work"\]' "${J[@]}" -X POST $U/tasks -d '{"title":"write docs","tags":["work"]}'
check "create with status" 201 '"status":"Doing"' "${J[@]}" -X POST $U/tasks -d '{"title":"buy milk","status":"Doing","tags":["home"]}'
check "blank title" 400 'title is required' "${J[@]}" -X POST $U/tasks -d '{"title":"  "}'
check "bad status" '4[0-9][0-9]' '' "${J[@]}" -X POST $U/tasks -d '{"title":"x","status":"Bogus"}'
check "create third" 201 '"id":3' "${J[@]}" -X POST $U/tasks -d '{"title":"alpha"}'
check "list sorted" 200 '"title":"alpha".*"title":"buy milk".*"title":"write docs"' $U/tasks
check "filter status" 200 '^\[\{[^{}]*"title":"buy milk"[^{}]*\}\]$' "$U/tasks?status=Doing"
check "filter tag" 200 '^\[\{[^{}]*"title":"write docs"[^{}]*\}\]$' "$U/tasks?tag=work"
check "bad status filter" '4[0-9][0-9]' '' "$U/tasks?status=Bogus"
check "set status" 200 '"status":"Done"' -X PUT "$U/tasks/1/status?status=Done"
check "set status missing" 404 '' -X PUT "$U/tasks/9/status?status=Done"
check "get" 200 '"title":"write docs" && "status":"Done"' $U/tasks/1
check "get missing" 404 '' $U/tasks/99
check "filter done" 200 '^\[\{[^{}]*"title":"write docs"[^{}]*\}\]$' "$U/tasks?status=Done"
check "stats" 200 '"total":3 && "done":1 && "open":2' $U/stats
echo "$lang: проверок провалено: $fails"
[[ $fails -eq 0 ]]
