#!/usr/bin/env bash
# Собрать, запустить и проверить решение:
#   eval/run.sh <задача> <язык> [папка решения]
# Язык: khrip (main.kh), go (модуль), csharp (проект), python (main.py, FastAPI app);
# для любого другого языка — START="команда запуска" eval/run.sh <задача> other <папка>.
# Папка по умолчанию — eval/solutions/<задача>/<язык>. Сервер слушает порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
task=$1
lang=$2
dir=$(cd "${3:-$here/solutions/$task/$lang}" && pwd) || exit 2
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

if curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/; then
	echo "порт 8080 уже занят" >&2
	exit 2
fi
export WINDOW_SECONDS=2 ASPNETCORE_URLS=http://127.0.0.1:8080
case $lang in
khrip)
	"$root/build/khc" -o "$tmp/server" "$dir/main.kh" || exit 2
	"$tmp/server" 2>"$tmp/log" &
	;;
go)
	(cd "$dir" && go build -o "$tmp/server" .) || exit 2
	"$tmp/server" &
	;;
csharp)
	dotnet build "$dir" -c Release -o "$tmp/cs" --nologo -v q >/dev/null || exit 2
	name=$(basename "$(ls "$dir"/*.csproj)" .csproj)
	dotnet "$tmp/cs/$name.dll" >/dev/null &
	;;
python)
	(cd "$dir" && exec python3 -m uvicorn main:app --port 8080 --log-level error) &
	;;
*)
	(cd "$dir" && exec bash -c "$START") &
	;;
esac
pid=$!
for _ in $(seq 600); do
	curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/ && break
	kill -0 $pid 2>/dev/null || {
		echo "сервер завершился при запуске" >&2
		exit 2
	}
	sleep 0.05
done
echo "== $task / $lang"
bash "$here/tasks/$task/check.sh"
