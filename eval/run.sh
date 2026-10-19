#!/usr/bin/env bash
# Собрать, запустить и проверить решение:
#   eval/run.sh <задача> <язык> [папка решения]
# Язык: khrip (main.kh), go (модуль), csharp (проект), python (main.py, FastAPI app);
# для любого другого языка — START="команда запуска" eval/run.sh <задача> other <папка>.
# Папка по умолчанию — eval/solutions/<задача>/<язык>. Сервер слушает порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/server.sh"
task=$1
lang=$2
dir=$(cd "${3:-$here/solutions/$task/$lang}" && pwd) || exit 2
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

if port_busy; then
	echo "порт 8080 уже занят" >&2
	exit 2
fi
export WINDOW_SECONDS=2
build_solution "$lang" "$dir" "$tmp" || exit 2
start_solution "$lang" "$dir" "$tmp"
wait_up || {
	echo "сервер не запустился" >&2
	exit 2
}
echo "== $task / $lang"
bash "$here/tasks/$task/check.sh"
